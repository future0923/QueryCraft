import SwiftUI

struct WorkspaceDataExportInlineTextField: View {
    let title: String
    let prompt: String
    @Binding var text: String

    @FocusState private var isFocused: Bool
    @State private var valueAtStartOfEditing = ""

    var body: some View {
        TextField(
            title,
            text: $text,
            prompt: Text(prompt)
        )
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .focused($isFocused)
        .onChange(of: isFocused) { _, newValue in
            if newValue {
                valueAtStartOfEditing = text
            }
        }
        .onSubmit {
            isFocused = false
        }
        .onExitCommand {
            guard isFocused else { return }
            text = valueAtStartOfEditing
            isFocused = false
        }
        .accessibilityLabel(title)
    }
}
