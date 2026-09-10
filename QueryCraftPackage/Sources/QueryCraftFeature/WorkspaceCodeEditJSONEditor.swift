import SwiftUI

struct WorkspaceCodeEditJSONEditor: View {
    @Binding var text: String

    var body: some View {
        WorkspaceJSONTextView(
            text: $text,
            isEditable: true,
            accessibilityLabel: AppCopy.current.text(
                "Elasticsearch 文档 JSON 编辑器",
                "Elasticsearch document JSON editor"
            )
        )
        .accessibilityIdentifier("elasticsearchDocumentJSONEditor")
    }

}
