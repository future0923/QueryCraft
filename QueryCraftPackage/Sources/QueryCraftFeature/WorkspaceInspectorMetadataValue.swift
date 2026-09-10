import SwiftUI

/// The existing relational table inspector's value presentation, shared by
/// resource inspectors so typography, borders and spacing stay identical.
struct WorkspaceInspectorMetadataValue: View {
    let value: String
    var allowsMultipleLines = false

    var body: some View {
        Text(value)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(allowsMultipleLines ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: allowsMultipleLines)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor))
            }
            .help(value)
    }
}
