import SwiftUI

struct WorkspaceElasticsearchMappingActionsView: View {
    let editor: WorkspaceElasticsearchMappingEditor
    let workspace: WorkspaceModel
    @State private var showsRaw = false

    var body: some View {
        HStack(spacing: 8) {
            Button(AppCopy.current.text("原始 JSON", "Raw JSON")) { showsRaw = true }
                .disabled(editor.snapshot == nil)
                .accessibilityIdentifier("mappingRawJSONButton")
                .popover(isPresented: $showsRaw) {
                    WorkspaceReadOnlyTextView(text: editor.rawText, usesMonospacedFont: true,
                        accessibilityLabel: AppCopy.current.text("原始 Mapping JSON", "Raw Mapping JSON"), showsBorder: false,
                        presentation: .json)
                        .frame(width: 600, height: 460)
                }

            Button(AppCopy.current.text("在控制台打开修改请求", "Open Update Request in Console")) {
                guard let snapshot = editor.snapshot else { return }
                let request = editor.prepared?.request
                let source = request.map { "\($0.method.rawValue) \($0.path)\n" + String(decoding: $0.body ?? Data(), as: UTF8.self) }
                    ?? Self.emptyRequestSource(for: snapshot.target.resource)
                workspace.openElasticsearchRequestSource(source)
            }
            .disabled(editor.snapshot == nil || editor.isCommitting)
            .accessibilityIdentifier("mappingOpenRequestButton")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .foregroundStyle(.primary)
    }

    static func emptyRequestSource(for target: String) -> String {
        // Keep URI-unreserved punctuation readable, matching prepared Mapping
        // paths, while encoding delimiters that could change the request target.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let path = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "PUT /\(path)/_mapping\n{\n  \"properties\": {}\n}"
    }
}
