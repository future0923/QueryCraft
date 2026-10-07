import Foundation
import Observation

@MainActor @Observable
final class WorkspaceKafkaTopicDeletionModel {
    let selection: WorkspaceDatabaseObjectSelection
    var confirmation = ""
    private(set) var isBusy = false
    private(set) var didDelete = false
    private(set) var needsVerification = false
    private(set) var error: String?

    init(selection: WorkspaceDatabaseObjectSelection) { self.selection = selection }

    var canDelete: Bool {
        selection.kind == .table && selection.databaseName == "Kafka"
            && (try? WorkspaceKafkaTopicDeletionRequest(topic: selection.objectName).validate()) != nil
            && confirmation == selection.objectName && !isBusy && !didDelete && !needsVerification
    }

    func submit(using delete: (WorkspaceDatabaseObjectSelection) async throws -> Void) async {
        guard canDelete else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await delete(selection)
            // Preserve a completed broker response even if the window closed.
            didDelete = true
        } catch let failure as WorkspaceKafkaTopicDeletionError {
            if case .unconfirmed = failure { needsVerification = true }
            error = failure.localizedDescription
        } catch {
            needsVerification = true
            self.error = WorkspaceKafkaTopicDeletionError.unconfirmed(error.localizedDescription).localizedDescription
        }
    }
}
