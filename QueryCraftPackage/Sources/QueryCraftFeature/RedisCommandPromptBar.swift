import SwiftUI

struct RedisCommandPromptBar: View {
    let databaseIndex: Int
    @Bindable var document: WorkspaceRedisCommandDocumentModel
    let focusRequest: Int
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Text("db\(databaseIndex)>")
                .font(.system(.body, design: .monospaced))
                .bold()
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)

            WorkspaceRedisCommandInputField(
                text: document.source,
                isEditable: !document.isExecuting,
                focusRequest: focusRequest,
                textChanged: document.updateSource,
                submit: submit,
                moveUp: moveUp,
                moveDown: moveDown,
                acceptCandidate: document.acceptSelectedCandidate,
                selectPreviousCandidate: document.selectPreviousCandidate,
                cancel: document.dismissCandidates
            )

            if document.isExecuting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        AppCopy.current.text("正在执行", "Executing")
                    )
                WorkspaceInlineIconButton(
                    systemImageName: "stop.fill",
                    title: AppCopy.current.text("停止", "Stop"),
                    isEnabled: true,
                    action: document.stop
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func moveUp() -> Bool {
        document.selectPreviousCandidate() || document.showPreviousCommand()
    }

    private func moveDown() -> Bool {
        document.selectNextCandidate() || document.showNextCommand()
    }
}
