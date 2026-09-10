import SwiftUI

struct WorkspaceElasticsearchObjectGroup: View {
    let databaseName: String
    let kind: WorkspaceDatabaseObjectKind
    let objects: [WorkspaceDatabaseObject]
    @Binding var isExpanded: Bool
    let openObjectTab: @MainActor (
        WorkspaceDatabaseObjectSelection,
        WorkspaceDatabaseObjectDetailTab
    ) -> Void
    var deleteIndex: @MainActor (WorkspaceDatabaseObjectSelection) -> Void = { _ in }

    var body: some View {
        if !objects.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(objects, id: \.id) { object in
                    let selection = WorkspaceDatabaseObjectSelection(
                        databaseName: databaseName,
                        objectName: object.name,
                        kind: kind
                    )
                    WorkspaceDatabaseObjectRow(
                        selection: selection,
                        displayName: object.name,
                        summary: object.summary,
                        openTab: { tab in openObjectTab(selection, tab) },
                        renameTable: {},
                        deleteTable: {},
                        deleteIndex: { deleteIndex(selection) }
                    )
                }
            } label: {
                Button(action: toggleExpansion) {
                    HStack {
                        Text(kind.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(objects.count, format: .number)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    "elasticsearchObjectGroup.\(kind.rawValue)"
                )
            }
        }
    }

    private var expansionBinding: Binding<Bool> {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return $isExpanded.transaction(transaction)
    }

    private func toggleExpansion() {
        expansionBinding.wrappedValue.toggle()
    }
}
