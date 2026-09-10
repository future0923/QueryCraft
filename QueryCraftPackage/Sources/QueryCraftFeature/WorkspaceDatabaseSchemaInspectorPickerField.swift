import SwiftUI

struct WorkspaceDatabaseSchemaInspectorPickerField<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.subheadline)
            .padding(.horizontal, 6)
            .frame(minHeight: 22)
            .background(
                Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}
