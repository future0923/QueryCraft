import SwiftUI

struct WorkspacePendingChangesPreviewView: View {
    let preview: WorkspacePendingChangesPreview
    let dismiss: @MainActor () -> Void

    @ViewBuilder
    var body: some View {
        switch preview {
        case .sql(let statements):
            WorkspaceSQLPreviewView(statements: statements, dismiss: dismiss)
        case .redis(let commands):
            WorkspaceRedisCommandPreviewView(commands: commands, dismiss: dismiss)
        case .elasticsearch(let requests):
            WorkspaceElasticsearchRequestPreviewView(
                requests: requests,
                dismiss: dismiss
            )
        }
    }
}
