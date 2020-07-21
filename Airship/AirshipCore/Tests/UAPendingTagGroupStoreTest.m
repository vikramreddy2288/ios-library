/* Copyright Airship and Contributors */

#import "UAAirshipBaseTest.h"
#import "UAPreferenceDataStore+Internal.h"
#import "UAPendingTagGroupStore+Internal.h"
#import "UATagGroupsRegistrar+Internal.h"
#import "UATagGroupHistorian.h"
#import "UAChannel+Internal.h"
#import "UANamedUser+Internal.h"

@interface UATagGroupHistorian()

- (NSArray<UATagGroupsMutation *> *)sentMutationsWithMaxAge:(NSTimeInterval)maxAge;

@end

@interface UAPendingTagGroupStoreTest : UAAirshipBaseTest

@property(nonatomic, strong) UAPendingTagGroupStore *channelPendingTagGroupStore;
@property(nonatomic, strong) UAPendingTagGroupStore *namedUserPendingTagGroupStore;
@property(nonatomic, strong) UATagGroupHistorian *tagGroupHistorian;

@end

@implementation UAPendingTagGroupStoreTest

- (void)setUp {
    [super setUp];
    self.channelPendingTagGroupStore = [UAPendingTagGroupStore historyWithDataStore:self.dataStore storeKey:UATagGroupsChannelStoreKey];
    self.namedUserPendingTagGroupStore = [UAPendingTagGroupStore historyWithDataStore:self.dataStore storeKey:UATagGroupsNamedUserStoreKey];
    
    UATagGroupsRegistrar *tagGroupsChannelRegistrar = [UATagGroupsRegistrar tagGroupsRegistrarWithConfig:self.config
                                                                                               dataStore:self.dataStore
                                                                                    pendingTagGroupStore:self.channelPendingTagGroupStore];
    UAChannel *channel = [UAChannel channelWithDataStore:self.dataStore
                                                  config:self.config
                                      tagGroupsRegistrar:tagGroupsChannelRegistrar];
    
    
    UATagGroupsRegistrar *tagGroupsNamedUserRegistrar = [UATagGroupsRegistrar tagGroupsRegistrarWithConfig:self.config
                                                                                                 dataStore:self.dataStore
                                                                                      pendingTagGroupStore:self.namedUserPendingTagGroupStore];
    UANamedUser *namedUser = [UANamedUser namedUserWithChannel:channel
                                                        config:self.config
                                                     dataStore:self.dataStore
                                            tagGroupsRegistrar:tagGroupsNamedUserRegistrar];
    
    self.tagGroupHistorian = [[UATagGroupHistorian alloc] initTagGroupHistorianWithChannel:channel namedUser:namedUser];
    
}

- (void)tearDown {
    [self.channelPendingTagGroupStore clearPendingMutations];
    [self.namedUserPendingTagGroupStore clearPendingMutations];
    [super tearDown];
}

- (void)testAddPendingMutation {
    UATagGroupsMutation *mutation = [UATagGroupsMutation mutationToAddTags:@[@"tag2"] group:@"group"];
    [self.channelPendingTagGroupStore addPendingMutation:mutation];

    UATagGroupsMutation *fromHistory = [self.channelPendingTagGroupStore popPendingMutation];
    XCTAssertEqualObjects(mutation.payload, fromHistory.payload);
}

- (void)testAddingPendingMutationsDoesntCollapseMutations {
    UATagGroupsMutation *add = [UATagGroupsMutation mutationToAddTags:@[@"tag1"] group:@"group"];
    UATagGroupsMutation *remove = [UATagGroupsMutation mutationToRemoveTags:@[@"tag2", @"tag1"] group:@"group"];

    [self.channelPendingTagGroupStore addPendingMutation:remove];
    [self.channelPendingTagGroupStore addPendingMutation:add];

    UATagGroupsMutation *fromHistory = [self.channelPendingTagGroupStore popPendingMutation];

    NSDictionary *expected = @{ @"remove": @{ @"group": @[@"tag2", @"tag1"] }};
    XCTAssertEqualObjects(expected, fromHistory.payload);

    fromHistory = [self.channelPendingTagGroupStore popPendingMutation];
    
    expected = @{ @"add": @{ @"group": @[@"tag1"] }};
    XCTAssertEqualObjects(expected, fromHistory.payload);
}

- (void)testCollapsePendingMutations {
    UATagGroupsMutation *add = [UATagGroupsMutation mutationToAddTags:@[@"tag1"] group:@"group"];
    UATagGroupsMutation *remove = [UATagGroupsMutation mutationToRemoveTags:@[@"tag2", @"tag1"] group:@"group"];

    [self.channelPendingTagGroupStore addPendingMutation:remove];
    [self.channelPendingTagGroupStore addPendingMutation:add];
    [self.channelPendingTagGroupStore collapsePendingMutations];
    
    UATagGroupsMutation *fromHistory = [self.channelPendingTagGroupStore popPendingMutation];
    
    NSDictionary *expected = @{ @"remove": @{ @"group": @[@"tag2"] }, @"add": @{ @"group": @[@"tag1"] } };
    XCTAssertEqualObjects(expected, fromHistory.payload);
}

- (void)testPeekPendingMutation {
    XCTAssertNil([self.channelPendingTagGroupStore peekPendingMutation]);
    
    UATagGroupsMutation *add = [UATagGroupsMutation mutationToAddTags:@[@"tag1"] group:@"group"];
    [self.channelPendingTagGroupStore addPendingMutation:add];
    
    UATagGroupsMutation *peekedMutation = [self.channelPendingTagGroupStore peekPendingMutation];
    XCTAssertNotNil(peekedMutation);
    UATagGroupsMutation *poppedMutation = [self.channelPendingTagGroupStore popPendingMutation];
    XCTAssertNotNil(poppedMutation);
    XCTAssertEqualObjects(peekedMutation.payload, poppedMutation.payload);
    XCTAssertNil([self.channelPendingTagGroupStore popPendingMutation]);
}

- (void)testPopPendingMutation {
    XCTAssertNil([self.channelPendingTagGroupStore popPendingMutation]);

    UATagGroupsMutation *add = [UATagGroupsMutation mutationToAddTags:@[@"tag1"] group:@"group"];
    [self.channelPendingTagGroupStore addPendingMutation:add];

    XCTAssertNotNil([self.channelPendingTagGroupStore popPendingMutation]);
    XCTAssertNil([self.channelPendingTagGroupStore popPendingMutation]);
}

- (void)testMigration {
    NSDictionary *oldAddTags = @{ @"group1": @[@"tag1"] };
    [self.dataStore setObject:oldAddTags forKey:@"UAPushAddTagGroups"];

    NSDictionary *oldRemoveTags = @{ @"group2": @[@"tag2"] };
    [self.dataStore setObject:oldRemoveTags forKey:@"UAPushRemoveTagGroups"];

    UATagGroupsMutation *oldMutation = [UATagGroupsMutation mutationToAddTags:@[@"foo", @"bar"] group:@"group1"];
    NSData *encodedMutations = [NSKeyedArchiver archivedDataWithRootObject:@[oldMutation]];
    [self.dataStore setObject:encodedMutations forKey:@"UAPushTagGroupsMutations"];

    UAPendingTagGroupStore *channelTagGroupsMutationHistory = [UAPendingTagGroupStore historyWithDataStore:self.dataStore storeKey:UATagGroupsChannelStoreKey];

    UATagGroupsMutation *oldAddRemoveFromHistory = [channelTagGroupsMutationHistory popPendingMutation];
    NSDictionary *expected = @{ @"add": @{ @"group1": @[@"tag1"] }, @"remove": @{ @"group2": @[@"tag2"] } };
    XCTAssertEqualObjects(expected, oldAddRemoveFromHistory.payload);

    UATagGroupsMutation *oldMutationFromHistory = [channelTagGroupsMutationHistory popPendingMutation];
    XCTAssertEqualObjects(oldMutation.payload, oldMutationFromHistory.payload);
}

- (void)testApplyMutations {
    UATagGroups *tagGroups = [UATagGroups tagGroupsWithTags:@{ @"group1": @[@"tag1", @"tag2"], @"group2" : @[@"tag3", @"tag4"] }];

    UATagGroupsMutation *mutation1 = [UATagGroupsMutation mutationToAddTags:@[@"foo", @"bar"] group:@"group1"];
    UATagGroupsMutation *mutation2 = [UATagGroupsMutation mutationToRemoveTags:@[@"tag3"] group:@"group2"];

    [self.channelPendingTagGroupStore addPendingMutation:mutation1];
    [self.channelPendingTagGroupStore addPendingMutation:mutation2];

    NSTimeInterval maxAge = 60 * 60;

    UATagGroupsMutation *mutation3 = [UATagGroupsMutation mutationToSetTags:@[@"baz", @"boz"] group:@"group3"];
    UATagGroupsMutation *mutation4 = [UATagGroupsMutation mutationToSetTags:@[@"bleep", @"bloop"] group:@"group4"];

    NSDate *recent = [NSDate dateWithTimeIntervalSinceNow:-(maxAge/2)];
    NSDate *old = [NSDate distantPast];

    [[NSNotificationCenter defaultCenter] postNotificationName:UAAirshipTagGroupSentNotification object:nil userInfo:@{@"tagGroupsMutation":mutation3, @"date":recent}];
    [[NSNotificationCenter defaultCenter] postNotificationName:UAAirshipTagGroupSentNotification object:nil userInfo:@{@"tagGroupsMutation":mutation4, @"date":old}];

    UATagGroups *newTagGroups = [self.tagGroupHistorian applyHistory:tagGroups maxAge:maxAge];

    UATagGroups *expectedTagGroups = [UATagGroups tagGroupsWithTags:@{ @"group1" : @[@"tag1", @"tag2", @"foo", @"bar"],
                                                                       @"group2" : @[@"tag4"],
                                                                       @"group3" : @[@"baz", @"boz"] }];

    XCTAssertEqualObjects(newTagGroups, expectedTagGroups);
}

- (void)testSentMutationsCleansOldRecords {
    UATagGroupsMutation *mutation1 = [UATagGroupsMutation mutationToSetTags:@[@"baz", @"boz"] group:@"group3"];
    UATagGroupsMutation *mutation2 = [UATagGroupsMutation mutationToSetTags:@[@"bleep", @"bloop"] group:@"group4"];

    NSTimeInterval maxAge = 60 * 60;

    NSDate *recent = [NSDate dateWithTimeIntervalSinceNow:-(maxAge/2)];
    NSDate *old = [NSDate distantPast];

    [[NSNotificationCenter defaultCenter] postNotificationName:UAAirshipTagGroupSentNotification object:nil userInfo:@{@"tagGroupsMutation":mutation1, @"date":recent}];
    [[NSNotificationCenter defaultCenter] postNotificationName:UAAirshipTagGroupSentNotification object:nil userInfo:@{@"tagGroupsMutation":mutation2, @"date":old}];

    NSArray<UATagGroupsMutation *> *sent = [self.tagGroupHistorian sentMutationsWithMaxAge:maxAge];

    XCTAssertEqual(sent.count, 1);
    XCTAssertEqualObjects(sent[0].payload, mutation1.payload);
}

@end