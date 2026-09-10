import SwiftUI

struct WorkspaceElasticsearchRequestPreviewView: View {
    let requests: [WorkspaceRequest]
    let dismiss: @MainActor () -> Void
    @State private var worker = WorkspaceElasticsearchConsoleWorker()
    @State private var displayedText = ""
    @State private var isFormatting = true

    var body: some View {
        WorkspaceJSONTextView(
            text: .constant(displayedText),
            isRequestPreview: true,
            accessibilityLabel: AppCopy.current.text("Elasticsearch 请求预览", "Elasticsearch Request Preview")
        )
        .frame(width: 600, height: 300)
        .overlay(alignment: .bottom) {
            WorkspaceDatabaseDataProgressBar(isActive: isFormatting)
        }
        .task(id: requests) {
            isFormatting = true
            do {
                let source = try await worker.previewSource(requests)
                try Task.checkCancellation()
                displayedText = source
                isFormatting = false
            } catch is CancellationError {
                // A dismissed or superseded preview must not publish stale text.
            } catch {
                isFormatting = false
            }
        }
        .background {
            WorkspaceSQLPreviewKeyCommandHandler(dismiss: dismiss)
        }
        .accessibilityLabel(
            AppCopy.current.text(
                "Elasticsearch 请求预览",
                "Elasticsearch Request Preview"
            )
        )
    }

}
