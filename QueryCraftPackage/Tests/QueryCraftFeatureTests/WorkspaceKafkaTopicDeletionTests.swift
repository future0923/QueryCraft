import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor @Suite("Kafka topic deletion", .timeLimit(.minutes(1)))
struct WorkspaceKafkaTopicDeletionTests {
    private let selection = WorkspaceDatabaseObjectSelection(databaseName: "Kafka", objectName: "events", kind: .table)

    @Test("Only an exact topic name confirmation can dispatch deletion")
    func confirmation() async {
        let editor = WorkspaceKafkaTopicDeletionModel(selection: selection)
        var calls: [WorkspaceDatabaseObjectSelection] = []
        for value in ["", "event", "events ", "EVENTS", "*"] {
            editor.confirmation = value
            await editor.submit { calls.append($0) }
            #expect(!editor.canDelete && calls.isEmpty)
        }
        editor.confirmation = "events"
        await editor.submit { calls.append($0) }
        #expect(calls == [selection] && editor.didDelete && !editor.canDelete)
        await editor.submit { calls.append($0) }
        #expect(calls.count == 1)
    }

    @Test("Internal topics and invalid single-topic names are never accepted",
          arguments: ["__consumer_offsets", "__transaction_state", "", ".", "..", "events,other", "events*", "events\0other", " events", "中文", String(repeating: "a", count: 250)])
    func invalidNames(_ name: String) {
        #expect(throws: WorkspaceKafkaTopicDeletionError.self) { try WorkspaceKafkaTopicDeletionRequest(topic: name).validate() }
    }

    @Test("A broker rejection retains the topic; an uncertain result blocks another submission")
    func failureHandling() async {
        let editor = WorkspaceKafkaTopicDeletionModel(selection: selection)
        editor.confirmation = "events"
        await editor.submit { _ in throw WorkspaceKafkaTopicDeletionError.rejected("ACL") }
        #expect(!editor.didDelete && editor.canDelete && editor.error?.contains("ACL") == true)
        await editor.submit { _ in throw WorkspaceKafkaTopicDeletionError.unconfirmed("timeout") }
        #expect(!editor.didDelete && !editor.canDelete && editor.needsVerification)
        await editor.submit { _ in Issue.record("An uncertain write must not be retried") }
    }

    @Test("Closing during a completed write preserves its acknowledgement")
    func acknowledgedCancellation() async {
        let editor = WorkspaceKafkaTopicDeletionModel(selection: selection)
        editor.confirmation = "events"
        let task = Task {
            await editor.submit { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        await task.value
        #expect(editor.didDelete && !editor.needsVerification)
    }

    @Test("A concurrent confirmation cannot send the same deletion twice")
    func concurrentSubmission() async {
        let editor = WorkspaceKafkaTopicDeletionModel(selection: selection)
        editor.confirmation = "events"
        await editor.submit { _ in
            #expect(editor.isBusy && !editor.canDelete)
            await editor.submit { _ in Issue.record("Duplicate deletion") }
        }
        #expect(editor.didDelete && !editor.isBusy)
    }
}
