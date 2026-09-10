import SwiftUI

struct WorkspaceSavedQueryGroup: View {
    let title: String
    let queries: [SavedQuery]
    let databaseNames: [String]
    let actions: WorkspaceSavedQueryActions
    var allowsMoving = true

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            ForEach(queries) { query in
                WorkspaceSavedQueryRow(
                    query: query,
                    databaseNames: databaseNames,
                    actions: actions,
                    allowsMoving: allowsMoving
                )
            }
        } label: {
            Button(action: toggleExpansion) {
                Text("\(title) (\(queries.count))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                "savedQueryGroup.\(title)"
            )
        }
    }

    private var expansionBinding: Binding<Bool> {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return $isExpanded.transaction(transaction)
    }

    private func toggleExpansion() {
        expansionBinding.wrappedValue = !isExpanded
    }
}
