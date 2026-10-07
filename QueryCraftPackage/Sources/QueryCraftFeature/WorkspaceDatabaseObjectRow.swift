import SwiftUI

struct WorkspaceDatabaseObjectRow: View {
    let selection: WorkspaceDatabaseObjectSelection
    let displayName: String
    let summary: WorkspaceDatabaseObjectSummary?
    let iconSystemImage: String?
    let allowsTableMutations: Bool
    let openTab: @MainActor (WorkspaceDatabaseObjectDetailTab) -> Void
    let renameTable: @MainActor () -> Void
    let deleteTable: @MainActor () -> Void
    var deleteIndex: (@MainActor () -> Void)? = nil
    var deleteTopic: (@MainActor () -> Void)? = nil

    init(
        selection: WorkspaceDatabaseObjectSelection,
        displayName: String,
        summary: WorkspaceDatabaseObjectSummary? = nil,
        openTab: @escaping @MainActor (WorkspaceDatabaseObjectDetailTab) -> Void,
        renameTable: @escaping @MainActor () -> Void,
        deleteTable: @escaping @MainActor () -> Void,
        deleteIndex: (@MainActor () -> Void)? = nil,
        deleteTopic: (@MainActor () -> Void)? = nil,
        iconSystemImage: String? = nil,
        allowsTableMutations: Bool = true
    ) {
        self.selection = selection
        self.displayName = displayName
        self.summary = summary
        self.openTab = openTab
        self.renameTable = renameTable
        self.deleteTable = deleteTable
        self.deleteIndex = deleteIndex
        self.deleteTopic = deleteTopic
        self.iconSystemImage = iconSystemImage
        self.allowsTableMutations = allowsTableMutations
    }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let documentCount = summary?.documentCount {
                    Text(documentCount, format: .number.notation(.compactName))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: iconSystemImage ?? selection.kind.systemImage)
        }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .tag(selection)
            .help(selection.objectName)
            .accessibilityIdentifier(
                "databaseObject.\(selection.databaseName).\(selection.objectName)"
            )
            .contextMenu {
                ForEach(
                    contextTabs
                ) { tab in
                    Button(tab.openTitle(for: selection.kind)) {
                        openTab(tab)
                    }
                }
                if selection.kind == .table && allowsTableMutations {
                    Divider()
                    Button(AppCopy.current.text("重命名表…", "Rename Table...")) {
                        renameTable()
                    }
                    Button(
                        AppCopy.current.text("删除表…", "Delete Table..."),
                        role: .destructive
                    ) {
                        deleteTable()
                    }
                }
                if WorkspaceIndexDeletionWorker.offersDeletion(selection), let deleteIndex {
                    Divider()
                    Button(AppCopy.current.text("删除索引…", "Delete Index..."), role: .destructive, action: deleteIndex)
                }
                if let deleteTopic {
                    Divider()
                    Button(AppCopy.current.text("删除 Topic…", "Delete Topic..."), role: .destructive, action: deleteTopic)
                        .disabled(selection.objectName.hasPrefix("__"))
                        .help(selection.objectName.hasPrefix("__")
                              ? AppCopy.current.text("Kafka 内部 Topic 不支持删除", "Kafka internal topics cannot be deleted")
                              : AppCopy.current.text("删除此 Topic 及其全部消息", "Delete this topic and all its messages"))
                }
            }
    }

    private var contextTabs: [WorkspaceDatabaseObjectDetailTab] {
        if selection.kind == .table && !allowsTableMutations {
            return [.data]
        }
        return WorkspaceDatabaseObjectDetailTab.available(for: selection.kind)
    }
}
