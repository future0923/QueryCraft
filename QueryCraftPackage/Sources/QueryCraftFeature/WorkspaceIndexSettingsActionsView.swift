import SwiftUI

struct WorkspaceIndexSettingsActionsView: View {
    let editor: WorkspaceElasticsearchIndexInspectorModel
    let workspace: WorkspaceModel
    @State private var showsSettings = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { rawSettingsButton; consoleButton }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { rawSettingsButton; consoleButton }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(isPresented: $showsSettings) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editor.snapshot?.selection.objectName ?? "").font(.headline).textSelection(.enabled)
                    Text(AppCopy.current.text("已加载的服务器 Settings（含 defaults），不含未提交草稿。", "Loaded server Settings, including defaults. Uncommitted drafts are not included."))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(12)
                Divider()
                WorkspaceReadOnlyTextView(text: editor.rawSettingsText, usesMonospacedFont: true,
                    accessibilityLabel: AppCopy.current.text("完整 Settings JSON", "Full Settings JSON"),
                    showsBorder: false, presentation: .json)
            }
            .frame(width: 600, height: 460)
        }
    }

    private var rawSettingsButton: some View {
        Button(AppCopy.current.text("查看完整 Settings", "View Full Settings")) { showsSettings = true }
            .disabled(editor.rawSettingsText.isEmpty)
            .accessibilityIdentifier("indexFullSettingsButton")
    }

    private var consoleButton: some View {
        Button(AppCopy.current.text("在控制台打开", "Open in Console")) {
            editor.openSettingsRequest(workspace: workspace)
        }
        .disabled(!editor.canOpenSettingsRequest)
        .help(editor.snapshot?.editableIndex != nil
            ? AppCopy.current.text("打开设置修改请求，不会自动执行。只填写需要修改的动态设置。", "Open a settings update request without executing it. Include only the dynamic settings to change.")
            : AppCopy.current.text("打开此资源的 Settings 查看请求，不会自动执行。", "Open a request to read this resource's Settings without executing it."))
        .accessibilityIdentifier("indexOpenSettingsRequestButton")
    }
}
