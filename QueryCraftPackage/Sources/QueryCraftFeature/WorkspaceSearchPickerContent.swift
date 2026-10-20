import AppKit
import SwiftUI

/// Shared search and selection surface used by grid columns and transfer locations.
struct WorkspaceSearchPickerContent<Option: Hashable, Rows: View>: View {
    @Binding var query: String
    @Binding var highlightedOption: Option?
    let focusRequest: Int
    let placeholder: String
    let accessibilityIdentifier: String
    let submit: () -> Void
    let cancel: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceGridSearchField(
                text: $query,
                placeholder: placeholder,
                focusRequest: focusRequest,
                submit: submit,
                cancel: cancel,
                accessibilityIdentifier: accessibilityIdentifier,
                moveUp: moveUp,
                moveDown: moveDown
            )
            .padding()

            ScrollViewReader { proxy in
                List(selection: $highlightedOption) { rows() }
                    .listStyle(.plain)
                    .scrollContentBackground(.visible)
                    .onChange(of: highlightedOption) { _, option in
                        guard let option else { return }
                        proxy.scrollTo(option, anchor: .center)
                    }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
