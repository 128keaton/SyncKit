//
//  QSRealmChangeManager.m
//  Pods
//
//  Created by Manuel Entrena on 05/05/2017.
//
//

#import "QSRealmChangeManager.h"
#import <Realm/Realm.h>
#import "QSSyncedEntity.h"
#import "QSRecord.h"
#import "QSSyncedEntityState.h"
#import "QSPendingRelationship.h"
#import "QSCloudKitSynchronizer.h"

@interface QSRealmProvider : NSObject

@property (nonatomic, readonly, strong) RLMRealm *persistenceRealm;
@property (nonatomic, readonly, strong) RLMRealm *targetRealm;

- (instancetype)initWithPersistenceConfiguration:(RLMRealmConfiguration *)persistenceConfiguration
                             targetConfiguration:(RLMRealmConfiguration *)targetConfiguration;

@end

@implementation QSRealmProvider

- (instancetype)initWithPersistenceConfiguration:(RLMRealmConfiguration *)persistenceConfiguration
                             targetConfiguration:(RLMRealmConfiguration *)targetConfiguration
{
    self = [super init];
    if (self) {
        _persistenceRealm = [RLMRealm realmWithConfiguration:persistenceConfiguration error:nil];
        _targetRealm = [RLMRealm realmWithConfiguration:targetConfiguration error:nil];
    }
    return self;
}

@end

typedef NS_ENUM(NSInteger, QSObjectUpdateType)
{
    QSObjectUpdateTypeInsertion,
    QSObjectUpdateTypeUpdate,
    QSObjectUpdateTypeDeletion
};

@interface QSObjectUpdate : NSObject

@property (nonatomic, strong) RLMObject *object;
@property (nonatomic, strong) NSString *identifier;
@property (nonatomic, strong) NSString *entityType;
@property (nonatomic, assign) QSObjectUpdateType updateType;
@property (nonatomic, strong) NSArray<RLMPropertyChange *> * _Nullable changes;

- (instancetype)initWithObject:(RLMObject *)object identifier:(NSString *)identifier entityType:(NSString *)entityType updateType:(QSObjectUpdateType)updateType;
- (instancetype)initWithObject:(RLMObject *)object identifier:(NSString *)identifier entityType:(NSString *)entityType updateType:(QSObjectUpdateType)updateType changes:(NSArray<RLMPropertyChange *> *)changes;

@end

@implementation QSObjectUpdate
- (instancetype)initWithObject:(RLMObject *)object identifier:(NSString *)identifier entityType:(NSString *)entityType updateType:(QSObjectUpdateType)updateType
{
    return [self initWithObject:object identifier:identifier entityType:entityType updateType:updateType changes:nil];
}
- (instancetype)initWithObject:(RLMObject *)object identifier:(NSString *)identifier entityType:(NSString *)entityType updateType:(QSObjectUpdateType)updateType changes:(NSArray<RLMPropertyChange *> *)changes
{
    self = [super init];
    if (self) {
        self.object = object;
        self.identifier = identifier;
        self.entityType = entityType;
        self.updateType = updateType;
        self.changes = changes;
    }
    return self;
}
@end

@interface QSRealmChangeManager ()

@property (nonatomic, strong, readwrite) RLMRealmConfiguration *persistenceConfiguration;
@property (nonatomic, strong, readwrite) RLMRealmConfiguration *targetConfiguration;
@property (nonatomic, strong, readwrite) CKRecordZoneID *recordZoneID;

@property (nonatomic, strong) NSMutableArray *collectionNotificationTokens;
@property (nonatomic, strong) NSMutableDictionary *objectNotificationTokens;
@property (nonatomic, strong) NSMutableArray *pendingTrackingUpdates;

@property (nonatomic, strong) QSRealmProvider *mainRealmProvider;

@property (nonatomic, assign) BOOL hasChanges;
@property (nonatomic, strong) dispatch_queue_t dispatchQueue;

@end

@implementation QSRealmChangeManager

- (instancetype)initWithPersistenceRealmConfiguration:(RLMRealmConfiguration *)configuration targetRealmConfiguration:(RLMRealmConfiguration *)targetRealmConfiguration recordZoneID:(CKRecordZoneID *)zoneID
{
    self = [super init];
    if (self) {
        self.persistenceConfiguration = configuration;
        self.targetConfiguration = targetRealmConfiguration;
        self.recordZoneID = zoneID;
        self.dispatchQueue = dispatch_queue_create("QSRealmChangeManager", DISPATCH_QUEUE_CONCURRENT);
        
        self.objectNotificationTokens = [NSMutableDictionary dictionary];
        self.collectionNotificationTokens = [NSMutableArray array];
        self.pendingTrackingUpdates = [NSMutableArray array];
        
        [self setup];
    }
    return self;
}

- (void)dealloc
{
    for (RLMNotificationToken *token in [self.objectNotificationTokens allValues]) {
        [token stop];
    }
    for (RLMNotificationToken *token in self.collectionNotificationTokens) {
        [token stop];
    }
}

+ (RLMRealmConfiguration *)defaultPersistenceConfiguration
{
    RLMRealmConfiguration *configuration = [[RLMRealmConfiguration alloc] init];
    configuration.objectClasses = @[[QSSyncedEntity class], [QSRecord class], [QSPendingRelationship class]];
    return configuration;
}

- (QSRealmProvider *)defaultProvider
{
    return [[QSRealmProvider alloc] initWithPersistenceConfiguration:self.persistenceConfiguration targetConfiguration:self.targetConfiguration];
}

- (void)setup
{
    self.mainRealmProvider = [self defaultProvider];
    
    BOOL needsInitialSetup = [[QSSyncedEntity allObjectsInRealm:self.mainRealmProvider.persistenceRealm] count] == 0;
    
    __weak QSRealmChangeManager *weakSelf = self;
    
    for (RLMObjectSchema *objectSchema in self.mainRealmProvider.targetRealm.schema.objectSchema) {
        Class objectClass = NSClassFromString(objectSchema.className);
        NSString *primaryKey = [objectClass primaryKey];
        RLMResults *results = [objectClass allObjectsInRealm:self.mainRealmProvider.targetRealm];
        
        //Register for insertions
        RLMNotificationToken *token = [results addNotificationBlock:^(RLMResults * _Nullable results, RLMCollectionChange * _Nullable change, NSError * _Nullable error) {
            for (NSNumber *index in change.insertions) {
                RLMObject *object = [results objectAtIndex:[index integerValue]];
                NSString *identifier = [object valueForKey:primaryKey];
                
                /* This can be called during a transaction, and it's illegal to add a notification block during a transaction,
                 * so we keep all the insertions in a list to be processed as soon as the realm finishes the current transaction
                 */
                if ([object.realm inWriteTransaction]) {
                    [self.pendingTrackingUpdates addObject:[[QSObjectUpdate alloc] initWithObject:object identifier:identifier entityType:objectSchema.className updateType:QSObjectUpdateTypeInsertion]];
                } else {
                    [self updateTrackingForInsertedObject:object withIdentifier:identifier entityName:objectSchema.className provider:self.mainRealmProvider];
                }
            }
        }];
        [self.collectionNotificationTokens addObject:token];
        
        for (RLMObject *object in results) {
            NSString *identifier = [object valueForKey:primaryKey];
            RLMNotificationToken *token = [object addNotificationBlock:^(BOOL deleted, NSArray<RLMPropertyChange *> * _Nullable changes, NSError * _Nullable error) {
                if ([self.mainRealmProvider.persistenceRealm inWriteTransaction]) {
                    [self.pendingTrackingUpdates addObject:[[QSObjectUpdate alloc] initWithObject:nil identifier:identifier entityType:objectSchema.className updateType:(deleted ? QSObjectUpdateTypeDeletion : QSObjectUpdateTypeUpdate) changes:changes]];
                } else {
                    [weakSelf updateTrackingForObjectIdentifier:identifier entityName:objectSchema.className inserted:NO deleted:deleted changes:changes realmProvider:self.mainRealmProvider];
                }
            }];
            if (needsInitialSetup) {
                [self createSyncedEntityForObjectOfType:objectSchema.className identifier:identifier inRealm:self.mainRealmProvider.persistenceRealm];
            }
            
            [self.objectNotificationTokens setObject:token forKey:identifier];
        }
    }
    
    RLMNotificationToken *token = [self.mainRealmProvider.targetRealm addNotificationBlock:^(RLMNotification  _Nonnull notification, RLMRealm * _Nonnull realm) {
        [weakSelf enqueueObjectUpdates];
    }];
    [self.collectionNotificationTokens addObject:token];
    
    [self updateHasChangesWithRealm:self.mainRealmProvider.persistenceRealm];
    if (self.hasChanges) {
        [[NSNotificationCenter defaultCenter] postNotificationName:QSChangeManagerHasChangesNotification object:self];
    }
}

/*
 *  We need to track newly inserted objects, but Realm doesn't allow adding a notification block
 *  when the realm is in a write transaction (and it might be, when the notification for the collection
 *  is received). The "inWriteTransaction" property doesn't seem to be KVO compliant, so we resort to
 *  periodically checking it until the realm finishes the current write transaction and we're free to
 *  add new notification blocks.
 */
- (void)enqueueObjectUpdates
{
    if (self.pendingTrackingUpdates.count) {
        if ([self.mainRealmProvider.targetRealm inWriteTransaction]) {
            __weak QSRealmChangeManager *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf enqueueObjectUpdates];
            });
        } else {
            [self updateObjectTracking];
        }
    }
}

- (void)updateObjectTracking
{
    QSRealmProvider *provider = [self defaultProvider];
    for (QSObjectUpdate *update in self.pendingTrackingUpdates) {
        if (update.updateType == QSObjectUpdateTypeInsertion) {
            [self updateTrackingForInsertedObject:update.object withIdentifier:update.identifier entityName:update.entityType provider:self.mainRealmProvider];
        } else {
            [self updateTrackingForObjectIdentifier:update.identifier entityName:update.entityType inserted:NO deleted:(update.updateType == QSObjectUpdateTypeDeletion) changes:update.changes realmProvider:provider];
        }
    }
    [self.pendingTrackingUpdates removeAllObjects];
}

- (void)updateTrackingForInsertedObject:(RLMObject *)object withIdentifier:(NSString *)identifier entityName:(NSString *)entityName provider:(QSRealmProvider *)provider
{
    __weak QSRealmChangeManager *weakSelf = self;
    RLMNotificationToken *token = [object addNotificationBlock:^(BOOL deleted, NSArray<RLMPropertyChange *> * _Nullable changes, NSError * _Nullable error) {
        [weakSelf updateTrackingForObjectIdentifier:identifier entityName:entityName inserted:NO deleted:deleted changes:changes realmProvider:self.mainRealmProvider];
    }];
    [self.objectNotificationTokens setObject:token forKey:identifier];
    
    [self updateTrackingForObjectIdentifier:identifier entityName:entityName inserted:YES deleted:NO changes:nil realmProvider:provider];
}

- (void)updateTrackingForObjectIdentifier:(NSString *)objectIdentifier entityName:(NSString *)entityName inserted:(BOOL)inserted deleted:(BOOL)deleted changes:(NSArray<RLMPropertyChange *> *)changes realmProvider:(QSRealmProvider *)provider
{
    BOOL isNewChange = NO;
    NSString *identifier = [NSString stringWithFormat:@"%@.%@", entityName, objectIdentifier];
    QSSyncedEntity *syncedEntity = [self syncedEntityForObjectWithIdentifier:identifier inRealm:self.mainRealmProvider.persistenceRealm];
    if (!syncedEntity) {
        syncedEntity = [self createSyncedEntityForObjectOfType:entityName identifier:objectIdentifier inRealm:provider.persistenceRealm];
        isNewChange = YES;
    } else if (!inserted) {
        NSMutableSet *changedKeys;
        if (syncedEntity.changedKeys) {
            changedKeys = [NSMutableSet setWithArray:[syncedEntity.changedKeys componentsSeparatedByString:@","]];
        } else {
            changedKeys = [NSMutableSet set];
        }
        
        for (RLMPropertyChange *propertyChange in changes) {
            if (!propertyChange.previousValue) {
                [changedKeys addObject:propertyChange.name];
                if (!isNewChange) {
                    isNewChange = YES;
                }
            }
        }
        
        if (isNewChange || deleted) {
            [provider.persistenceRealm beginWriteTransaction];
            syncedEntity.state = deleted ? @(QSSyncedEntityStateDeleted) : @(QSSyncedEntityStateChanged);
            syncedEntity.changedKeys = [[changedKeys allObjects] componentsJoinedByString:@","];
            [provider.persistenceRealm commitWriteTransaction];
        }
    }
    
    if (deleted) {
        RLMNotificationToken *token = [self.objectNotificationTokens objectForKey:objectIdentifier];
        if (token) {
            [self.objectNotificationTokens removeObjectForKey:objectIdentifier];
            [token stop];
        }
        isNewChange = YES;
    }
    
    if (!self.hasChanges && isNewChange) {
        self.hasChanges = YES;
        if (self.hasChanges) {
            [[NSNotificationCenter defaultCenter] postNotificationName:QSChangeManagerHasChangesNotification object:self];
        }
    }
}

- (QSSyncedEntity *)createSyncedEntityForObjectOfType:(NSString *)entityName identifier:(NSString *)objectIdentifier inRealm:(RLMRealm *)realm
{
    QSSyncedEntity *syncedEntity = [[QSSyncedEntity alloc] init];
    syncedEntity.identifier = [NSString stringWithFormat:@"%@.%@", entityName, objectIdentifier];
    syncedEntity.entityType = entityName;
    syncedEntity.state = @(QSSyncedEntityStateNew);
    
    [realm beginWriteTransaction];
    [realm addObject:syncedEntity];
    [realm commitWriteTransaction];
    
    return syncedEntity;
}

- (QSSyncedEntity *)createSyncedEntityForRecord:(CKRecord *)record realmProvider:(QSRealmProvider *)provider
{
    QSSyncedEntity *syncedEntity = [[QSSyncedEntity alloc] init];
    syncedEntity.identifier = record.recordID.recordName;
    syncedEntity.entityType = record.recordType;
    syncedEntity.state = @(QSSyncedEntityStateSynced);
    
    
    [provider.persistenceRealm addObject:syncedEntity];
    
    Class objectClass = NSClassFromString(record.recordType);
    NSString *primaryKey = [objectClass primaryKey];
    NSString *objectIdentifier = [self objectIdentifierForSyncedEntity:syncedEntity];
    RLMObject *object = [[objectClass alloc] initWithValue:@{primaryKey: objectIdentifier}];
    
    [provider.targetRealm addObject:object];
    
    return syncedEntity;
}

- (void)updateHasChangesWithRealm:(RLMRealm *)realm
{
    RLMResults *results = [QSSyncedEntity objectsInRealm:realm where:@"state != %@", @(QSSyncedEntityStateSynced)];
    self.hasChanges = results.count > 0;
}

- (QSSyncedEntity *)syncedEntityForObjectWithIdentifier:(NSString *)identifier inRealm:(RLMRealm *)realm
{
    return [QSSyncedEntity objectInRealm:realm forPrimaryKey:identifier];
}

- (NSString *)objectIdentifierForSyncedEntity:(QSSyncedEntity *)syncedEntity
{
    return [syncedEntity.identifier substringFromIndex:syncedEntity.entityType.length + 1]; // entityName-objectIdentifier
}

- (void)applyChangesInRecord:(CKRecord *)record toObject:(RLMObject *)object withSyncedEntity:(QSSyncedEntity *)syncedEntity realmProvider:(QSRealmProvider *)provider
{
    if ([syncedEntity.state integerValue] == QSSyncedEntityStateChanged || [syncedEntity.state integerValue] == QSSyncedEntityStateNew) {
        if (self.mergePolicy == QSCloudKitSynchronizerMergePolicyServer) {
            for (NSString *key in record.allKeys) {
                if ([self shouldIgnoreKey:key]) {
                    continue;
                }
                
                [self applyChangeForProperty:key inRecord:record toObject:object withSyncedEntity:syncedEntity realmProvider:provider];
            }
        } else if (self.mergePolicy == QSCloudKitSynchronizerMergePolicyClient) {
            NSArray *changedKeys = syncedEntity.changedKeys ? [syncedEntity.changedKeys componentsSeparatedByString:@","] : @[];
            for (NSString *key in record.allKeys) {
                if ([self shouldIgnoreKey:key] ||
                    [changedKeys containsObject:key] ||
                    ([syncedEntity.state integerValue] == QSSyncedEntityStateNew && [object valueForKey:key] != nil)) {
                    continue;
                }
                
               [self applyChangeForProperty:key inRecord:record toObject:object withSyncedEntity:syncedEntity realmProvider:provider];
            }
        } else if (self.mergePolicy == QSCloudKitSynchronizerMergePolicyCustom) {
            NSMutableDictionary *recordChanges = [NSMutableDictionary dictionary];
            [record.allKeys enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                if (![record[obj] isKindOfClass:[CKReference class]]) {
                    recordChanges[obj] = record[obj];
                }
            }];
            if ([self.delegate respondsToSelector:@selector(changeManager:gotChanges:forObject:)]) {
                [self.delegate changeManager:self gotChanges:[recordChanges copy] forObject:object];
            }
        }
    } else {
        for (NSString *key in record.allKeys) {
            if ([self shouldIgnoreKey:key]) {
                continue;
            }
            
            [self applyChangeForProperty:key inRecord:record toObject:object withSyncedEntity:syncedEntity realmProvider:provider];
        }
    }
}

- (void)applyChangeForProperty:(NSString *)key inRecord:(CKRecord *)record toObject:(RLMObject *)object withSyncedEntity:(QSSyncedEntity *)syncedEntity realmProvider:(QSRealmProvider *)provider
{
    if ([record[key] isKindOfClass:[CKReference class]]) {
        // Save relationship to be applied after all records have been downloaded and persisted
        // to ensure target of the relationship has already been created
        CKReference *reference = record[key];
        NSRange separatorRange = [reference.recordID.recordName rangeOfString:@"."];
        NSString *objectIdentifier = [reference.recordID.recordName substringFromIndex:separatorRange.location + 1];
        [self savePendingRelationshipWithName:key syncedEntity:syncedEntity targetIdentifier:objectIdentifier realm:provider.persistenceRealm];
    } else if (![key isEqualToString:object.objectSchema.primaryKeyProperty.name]) {
        [object setValue:record[key] forKey:key];
    }
}

- (void)savePendingRelationshipWithName:(NSString *)name syncedEntity:(QSSyncedEntity *)syncedEntity targetIdentifier:(NSString *)targetID realm:(RLMRealm *)realm
{
    QSPendingRelationship *pendingRelationship = [[QSPendingRelationship alloc] init];
    pendingRelationship.relationshipName = name;
    pendingRelationship.forSyncedEntity = syncedEntity;
    pendingRelationship.targetIdentifier = targetID;
    [realm addObject:pendingRelationship];
}

- (void)applyPendingRelationshipsWithRealmProvider:(QSRealmProvider *)provider
{
    RLMResults *pendingRelationships = [QSPendingRelationship allObjectsInRealm:provider.persistenceRealm];
    
    if (pendingRelationships.count == 0) {
        return;
    }
    
    [provider.persistenceRealm beginWriteTransaction];
    [provider.targetRealm beginWriteTransaction];
    for (QSPendingRelationship *relationship in pendingRelationships) {
        QSSyncedEntity *syncedEntity = relationship.forSyncedEntity;
        Class originObjectClass = NSClassFromString(syncedEntity.entityType);
        NSString *objectIdentifier = [self objectIdentifierForSyncedEntity:syncedEntity];
        RLMObject *origin = [originObjectClass objectInRealm:provider.targetRealm forPrimaryKey:objectIdentifier];
        
        NSString *targetClassName = nil;
        for (RLMProperty *property in origin.objectSchema.properties) {
            if ([property.name isEqualToString:relationship.relationshipName]) {
                targetClassName = property.objectClassName;
                break;
            }
        }
        if (!targetClassName) {
            return;
        }
        
        Class targetObjectClass = NSClassFromString(targetClassName);
        RLMObject *targetObject = [targetObjectClass objectInRealm:provider.targetRealm forPrimaryKey:relationship.targetIdentifier];
        
        [origin setValue:targetObject forKey:relationship.relationshipName];
        
        [provider.persistenceRealm deleteObject:relationship];
    }
    [provider.persistenceRealm commitWriteTransaction];
    [provider.targetRealm commitWriteTransaction];
}

- (void)saveRecord:(CKRecord *)record forSyncedEntity:(QSSyncedEntity *)syncedEntity
{
    QSRecord *qsRecord = syncedEntity.record;
    if (!qsRecord) {
        qsRecord = [[QSRecord alloc] init];
        syncedEntity.record = qsRecord;
    }
    qsRecord.encodedRecord = [self encodedRecord:record];
}

- (NSData *)encodedRecord:(CKRecord *)record
{
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    [record encodeSystemFieldsWithCoder:archiver];
    [archiver finishEncoding];
    return [data copy];
}

- (CKRecord *)recordForSyncedEntity:(QSSyncedEntity *)entity
{
    CKRecord *record = nil;
    if (entity.record) {
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:entity.record.encodedRecord];
        record = [[CKRecord alloc] initWithCoder:unarchiver];
        [unarchiver finishDecoding];
    }
    return record;
}

- (BOOL)shouldIgnoreKey:(NSString *)key
{
    return [[QSCloudKitSynchronizer synchronizerMetadataKeys] containsObject:key];
}

- (CKRecord *)recordToUploadForSyncedEntity:(QSSyncedEntity *)syncedEntity realmProvider:(QSRealmProvider *)realmProvider
{
    CKRecord *record = [self recordForSyncedEntity:syncedEntity];
    if (!record) {
        record = [[CKRecord alloc] initWithRecordType:syncedEntity.entityType recordID:[[CKRecordID alloc] initWithRecordName:syncedEntity.identifier zoneID:self.recordZoneID]];
    }
    
    Class objectClass = NSClassFromString(syncedEntity.entityType);
    NSString *objectIdentifier = [self objectIdentifierForSyncedEntity:syncedEntity];
    RLMObject *object = [objectClass objectInRealm:realmProvider.targetRealm forPrimaryKey:objectIdentifier];
    
    NSArray *changedKeys = [(syncedEntity.changedKeys ?: @"") componentsSeparatedByString:@","];
    
    for (RLMProperty *property in object.objectSchema.properties) {
        if (property.type == RLMPropertyTypeObject &&
            ([syncedEntity.state integerValue] == QSSyncedEntityStateNew || [changedKeys containsObject:property.name])) {
            RLMObject *target = [object valueForKey:property.name];
            if (target) {
                NSString *targetIdentifier = [target valueForKey:[[target class] primaryKey]];
                NSString *referenceIdentifier = [NSString stringWithFormat:@"%@.%@", property.objectClassName, targetIdentifier];
                record[property.name] = [[CKReference alloc] initWithRecordID:[[CKRecordID alloc] initWithRecordName:referenceIdentifier zoneID:self.recordZoneID] action:CKReferenceActionNone];
            }
        } else if (property.type != RLMPropertyTypeArray &&
                   property.type != RLMPropertyTypeLinkingObjects &&
                   ([syncedEntity.state integerValue] == QSSyncedEntityStateNew || [changedKeys containsObject:property.name])) {
            record[property.name] = [object valueForKey:property.name];
        }
    }
    
    return record;
}

- (NSArray *)recordsToUploadWithState:(QSSyncedEntityState)state limit:(NSInteger)limit realmProvider:(QSRealmProvider *)realmProvider
{
    RLMResults<QSSyncedEntity *> *results = [QSSyncedEntity objectsInRealm:realmProvider.persistenceRealm where:@"state == %@", @(state)];
    NSMutableArray *resultArray = [NSMutableArray array];
    for (QSSyncedEntity *syncedEntity in results) {
        if (resultArray.count > limit) {
            break;
        }
        
        [resultArray addObject:[self recordToUploadForSyncedEntity:syncedEntity realmProvider:realmProvider]];
    }
    
    return [resultArray copy];
}

- (QSSyncedEntityState)nextStateToSyncAfter:(QSSyncedEntityState)state
{
    return state + 1;
}

#pragma mark - QSChangeManager


- (void)prepareForImport
{
}

- (void)saveChangesInRecords:(NSArray<CKRecord *> *)records
{
    if (records.count == 0) {
        return;
    }
    
    dispatch_sync(self.dispatchQueue, ^{
        QSRealmProvider *provider = [self defaultProvider];
        
        [provider.persistenceRealm beginWriteTransaction];
        [provider.targetRealm beginWriteTransaction];
        for (CKRecord *record in records) {
            QSSyncedEntity *syncedEntity = [self syncedEntityForObjectWithIdentifier:record.recordID.recordName inRealm:provider.persistenceRealm];
            
            if (!syncedEntity) {
                syncedEntity = [self createSyncedEntityForRecord:record realmProvider:provider];
            }
            
            Class objectClass = NSClassFromString(record.recordType);
            NSString *objectIdentifier = [self objectIdentifierForSyncedEntity:syncedEntity];
            RLMObject *object = [objectClass objectInRealm:provider.targetRealm forPrimaryKey:objectIdentifier];
            
            [self applyChangesInRecord:record toObject:object withSyncedEntity:syncedEntity realmProvider:provider];
            
            [self saveRecord:record forSyncedEntity:syncedEntity];
        }
        // Order is important here. Notifications might be delivered after targetRealm is saved and
        // it's convenient if the persistenceRealm is not in a write transaction
        [provider.persistenceRealm commitWriteTransaction];
        [provider.targetRealm commitWriteTransaction];
    });
}

- (void)deleteRecordsWithIDs:(NSArray<CKRecordID *> *)recordIDs
{
    if (recordIDs.count == 0) {
        return;
    }
    
    dispatch_sync(self.dispatchQueue, ^{
        QSRealmProvider *provider = [self defaultProvider];
        
        [provider.persistenceRealm beginWriteTransaction];
        [provider.targetRealm beginWriteTransaction];
        for (CKRecordID *recordID in recordIDs) {
            QSSyncedEntity *syncedEntity = [self syncedEntityForObjectWithIdentifier:recordID.recordName inRealm:provider.persistenceRealm];
            if (syncedEntity) {
                Class objectClass = NSClassFromString(syncedEntity.entityType);
                NSString *objectIdentifier = [self objectIdentifierForSyncedEntity:syncedEntity];
                RLMObject *object = [objectClass objectInRealm:provider.targetRealm forPrimaryKey:objectIdentifier];
                
                [provider.persistenceRealm deleteObject:syncedEntity];
                
                if (object) {
                    RLMNotificationToken *token = [self.objectNotificationTokens objectForKey:objectIdentifier];
                    if (token) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self.objectNotificationTokens removeObjectForKey:objectIdentifier];
                            [token stop];
                        });
                    }
                    
                    [provider.targetRealm deleteObject:object];
                }
            }
        }
        [provider.persistenceRealm commitWriteTransaction];
        [provider.targetRealm commitWriteTransaction];
    });
}


- (void)persistImportedChangesWithCompletion:(void(^)(NSError *error))completion
{
    //Apply pending relationships
    dispatch_sync(self.dispatchQueue, ^{
        QSRealmProvider *provider = [self defaultProvider];
        [self applyPendingRelationshipsWithRealmProvider:provider];
    });
    
    completion(nil);
}


- (NSArray *)recordsToUploadWithLimit:(NSInteger)limit
{
    __block NSArray *recordsArray = @[];
    dispatch_sync(self.dispatchQueue, ^{
        QSRealmProvider *provider = [[QSRealmProvider alloc] initWithPersistenceConfiguration:self.persistenceConfiguration targetConfiguration:self.targetConfiguration];
        
        NSInteger recordLimit = limit;
        QSSyncedEntityState uploadingState = QSSyncedEntityStateNew;
        
        if (recordLimit == 0) { recordLimit = NSIntegerMax; }
        
        NSInteger innerLimit = recordLimit;
        while (recordsArray.count < recordLimit && uploadingState < QSSyncedEntityStateDeleted) {
            recordsArray = [recordsArray arrayByAddingObjectsFromArray:[self recordsToUploadWithState:uploadingState limit:innerLimit realmProvider:provider]];
            uploadingState = [self nextStateToSyncAfter:uploadingState];
            innerLimit = recordLimit - recordsArray.count;
        }
    });
    
    return recordsArray;
}


- (void)didUploadRecords:(NSArray *)savedRecords
{
    dispatch_sync(self.dispatchQueue, ^{
        QSRealmProvider *provider = [self defaultProvider];
        [provider.persistenceRealm beginWriteTransaction];
        for (CKRecord *record in savedRecords) {
            QSSyncedEntity *syncedEntity = [QSSyncedEntity objectInRealm:provider.persistenceRealm forPrimaryKey:record.recordID.recordName];
            syncedEntity.state = @(QSSyncedEntityStateSynced);
        }
        [provider.persistenceRealm commitWriteTransaction];
    });
}


- (NSArray *)recordIDsMarkedForDeletionWithLimit:(NSInteger)limit
{
    NSMutableArray *recordIDs = [NSMutableArray array];
    dispatch_sync(self.dispatchQueue, ^{
        QSRealmProvider *provider = [self defaultProvider];
        RLMResults<QSSyncedEntity *> *deletedEntities = [QSSyncedEntity objectsInRealm:provider.persistenceRealm where:@"state == %@", @(QSSyncedEntityStateDeleted)];
        
        for (QSSyncedEntity *syncedEntity in deletedEntities) {
            if (recordIDs.count > limit) {
                break;
            }
            
            [recordIDs addObject:[[CKRecordID alloc] initWithRecordName:syncedEntity.identifier zoneID:self.recordZoneID]];
        }
    });
    
    return [recordIDs copy];
}


- (void)didDeleteRecordIDs:(NSArray *)deletedRecordIDs
{
    dispatch_sync(self.dispatchQueue, ^{
        QSRealmProvider *provider = [self defaultProvider];
        
        [provider.persistenceRealm beginWriteTransaction];
        for (CKRecordID *recordID in deletedRecordIDs) {
            
            QSSyncedEntity *syncedEntity = [[QSSyncedEntity objectsInRealm:provider.persistenceRealm where:@"identifier == %@", recordID.recordName] firstObject];
            if (syncedEntity) {
                [provider.persistenceRealm deleteObject:syncedEntity];
            }
        }
        [provider.persistenceRealm commitWriteTransaction];
    });
}


- (BOOL)hasRecordID:(CKRecordID *)recordID
{
    QSRealmProvider *provider = [self defaultProvider];
    QSSyncedEntity *syncedEntity = [[QSSyncedEntity objectsInRealm:provider.persistenceRealm where:@"identifier == %@", recordID.recordName] firstObject];
    return (syncedEntity != nil);
}


- (void)didFinishImportWithError:(NSError *)error
{
    dispatch_sync(self.dispatchQueue, ^{
        QSRealmProvider *provider = [self defaultProvider];
        [self updateHasChangesWithRealm:provider.persistenceRealm];
    });
}

- (void)deleteChangeTracking
{
    NSFileManager *manager = [NSFileManager defaultManager];
    RLMRealmConfiguration *config = self.persistenceConfiguration;
    NSArray<NSURL *> *realmFileURLs = @[
                                        config.fileURL,
                                        [config.fileURL URLByAppendingPathExtension:@"lock"],
                                        [config.fileURL URLByAppendingPathExtension:@"note"],
                                        [config.fileURL URLByAppendingPathExtension:@"management"]
                                        ];
    for (NSURL *URL in realmFileURLs) {
        NSError *error = nil;
        [manager removeItemAtURL:URL error:&error];
        if (error) {
            // handle error
        }
    }
}

@end
