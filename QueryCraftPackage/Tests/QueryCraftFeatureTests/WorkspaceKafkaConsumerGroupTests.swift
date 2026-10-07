import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceKafkaConsumerGroupTests {
    @Test func pendingMessagesStartAtCommittedOffsetWithoutSkippingIt() throws {
        let row = WorkspaceKafkaConsumerOffset(partition: 2, committedOffset: 42, beginningOffset: 10, endOffset: 50)
        let request = try #require(row.pendingMessagesReadRequest)
        #expect(request.partition == 2)
        #expect(request.start == .offset(42))
        #expect(request.isValid)
        let first = WorkspaceKafkaConsumerOffset(partition: 0, committedOffset: 0, beginningOffset: 0, endOffset: 1)
        #expect(first.pendingMessagesReadRequest?.start == .offset(0))
    }

    @Test func pendingMessagesRequireKnownLagWithinTheRetainedLog() {
        let unavailable: [WorkspaceKafkaConsumerOffset] = [
            .init(partition: 0, committedOffset: nil, beginningOffset: 0, endOffset: 10),
            .init(partition: 0, committedOffset: 10, beginningOffset: 0, endOffset: 10),
            .init(partition: 0, committedOffset: 2, beginningOffset: 3, endOffset: 10),
            .init(partition: 0, committedOffset: 11, beginningOffset: 0, endOffset: 10),
            .init(partition: 0, committedOffset: 2, beginningOffset: nil, endOffset: 10),
            .init(partition: 0, committedOffset: 2, beginningOffset: 0, endOffset: nil),
            .init(partition: 0, committedOffset: 2, beginningOffset: 0, endOffset: 10, error: "permission denied"),
            .init(partition: -1, committedOffset: 2, beginningOffset: 0, endOffset: 10),
        ]
        for row in unavailable { #expect(row.pendingMessagesReadRequest == nil) }
    }

    @Test func lagSummaryDoesNotTreatMissingPartitionsOrOverflowAsZero() {
        let known = [WorkspaceKafkaConsumerOffset(partition: 0, committedOffset: 3, beginningOffset: 0, endOffset: 10),
                     .init(partition: 1, committedOffset: 10, beginningOffset: 0, endOffset: 10)]
        let summary = WorkspaceKafkaLagSummary(offsets: known)
        #expect(summary.totalLag == 7)
        #expect(summary.laggingPartitions == 1)
        #expect(summary.unknownPartitions == 0)
        let partial = WorkspaceKafkaLagSummary(offsets: known + [.init(partition: 2, committedOffset: nil, beginningOffset: 0, endOffset: 10)])
        #expect(partial.totalLag == nil)
        #expect(partial.knownLag == 7)
        #expect(partial.unknownPartitions == 1)
        #expect(WorkspaceKafkaLagSummary(offsets: []).totalLag == nil)
        let overflow = WorkspaceKafkaLagSummary(offsets: [
            .init(partition: 0, committedOffset: 0, beginningOffset: 0, endOffset: Int64.max),
            .init(partition: 1, committedOffset: 0, beginningOffset: 0, endOffset: 1)])
        #expect(overflow.totalLag == nil)
        #expect(overflow.knownLag == nil)
    }

    @Test func topicHealthAndSensitiveConfigurationArePreserved() {
        #expect(WorkspaceKafkaTopicPartition(id: 0, leader: 1, replicas: [1, 2], inSyncReplicas: [2, 1]).isUnderReplicated == false)
        #expect(WorkspaceKafkaTopicPartition(id: 0, leader: 1, replicas: [1, 2], inSyncReplicas: [1]).isUnderReplicated)
        #expect(WorkspaceKafkaTopicConfiguration(name: "secret", value: "must-not-display", isDefault: false, isSensitive: true).value == nil)
    }

    @Test func lagOnlyUsesKnownOffsetsInTheRetainedLog() {
        #expect(WorkspaceKafkaConsumerOffset(partition: 0, committedOffset: 3, beginningOffset: 0, endOffset: 10).lag == 7)
        #expect(WorkspaceKafkaConsumerOffset(partition: 0, committedOffset: 10, beginningOffset: 0, endOffset: 10).lag == 0)
        for row in [
            WorkspaceKafkaConsumerOffset(partition: 0, committedOffset: nil, beginningOffset: 0, endOffset: 10),
            .init(partition: 0, committedOffset: 3, beginningOffset: 4, endOffset: 10),
            .init(partition: 0, committedOffset: 11, beginningOffset: 0, endOffset: 10),
            .init(partition: 0, committedOffset: 3, beginningOffset: nil, endOffset: nil),
            .init(partition: 0, committedOffset: 3, beginningOffset: 0, endOffset: 10, error: "permission denied"),
        ] { #expect(row.lag == nil) }
    }

    @Test func authenticationSurvivesSaveEditAndDatabaseSelection() async throws {
        let repository = SQLiteConnectionProfileRepository(databaseURL: nil)
        for mechanism in KafkaSASLMechanism.allCases {
            var draft = ConnectionProfileDraft(databaseProduct: .kafka)
            draft.name = mechanism.rawValue
            draft.username = "reader"
            draft.password = "test-secret"
            draft.authenticationMethod = .usernamePassword
            draft.kafkaSASLMechanism = mechanism
            let profile = try draft.makeProfile()
            try await repository.insert(profile)
            let restored = try #require(await repository.fetch(id: profile.id))
            let edited = ConnectionProfileDraft(profile: restored, password: "test-secret")
            let configuration = try edited.makeConnectionConfiguration()
            #expect(edited.kafkaSASLMechanism == mechanism)
            #expect(restored.kafkaSASLMechanism == mechanism)
            #expect(configuration.authentication == .usernamePassword(username: "reader", password: "test-secret"))
            let serialized = try JSONEncoder().encode(restored)
            #expect(!String(decoding: serialized, as: UTF8.self).contains("test-secret"))
        }
    }

    @Test func olderConnectionProfilesDefaultToPlain() throws {
        var draft = ConnectionProfileDraft(databaseProduct: .kafka)
        draft.name = "old"
        let profile = try draft.makeProfile()
        let data = try JSONEncoder().encode(profile)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "kafkaSASLMechanism")
        let old = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(ConnectionProfileDraft(profile: old).kafkaSASLMechanism == .plain)
    }
}
