import SwiftUI

struct WorkspaceInspectorColumnComment: View {
    let comment: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundStyle(Color(nsColor: WorkspaceSQLGridHeader.commentColor(isDark: colorScheme == .dark)))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(comment)
                .accessibilityIdentifier("workspaceInspectorColumnComment")
        }
    }
}
