import SwiftUI

struct WorkspaceSavedQueryRow: View {
    let query: SavedQuery
    let databaseNames: [String]
    let actions: WorkspaceSavedQueryActions
    var allowsMoving = true

    var body: some View {
        Label(query.name, systemImage: "doc.text")
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .help(query.name)
            .onTapGesture(count: 2, perform: open)
            .contextMenu {
                Button(
                    AppCopy.current.text("重命名…", "Rename..."),
                    systemImage: "pencil",
                    action: rename
                )
                Button(
                    AppCopy.current.text("复制", "Duplicate"),
                    systemImage: "plus.square.on.square",
                    action: duplicate
                )
                if allowsMoving {
                    Menu(
                        AppCopy.current.text("移动到", "Move To"),
                        systemImage: "folder"
                    ) {
                        Button(
                            AppCopy.current.text("通用查询", "General Queries"),
                            systemImage: "tray",
                            action: moveToGeneralQueries
                        )
                        .disabled(query.defaultDatabase == nil)

                        if !databaseNames.isEmpty {
                            Divider()
                            ForEach(databaseNames, id: \.self) { databaseName in
                                Button(
                                    databaseName,
                                    systemImage: "cylinder",
                                    action: { move(to: databaseName) }
                                )
                                .disabled(query.defaultDatabase == databaseName)
                            }
                        }
                    }
                }
                Divider()
                Button(
                    AppCopy.current.text("删除", "Delete"),
                    systemImage: "trash",
                    role: .destructive,
                    action: delete
                )
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(
                named: AppCopy.current.text("打开", "Open"),
                open
            )
            .accessibilityIdentifier("savedQuery.\(query.id.uuidString)")
    }

    private func open() {
        actions.open(query.id)
    }

    private func rename() {
        actions.rename(query.id)
    }

    private func duplicate() {
        actions.duplicate(query.id)
    }

    private func moveToGeneralQueries() {
        actions.move(query.id, nil)
    }

    private func move(to databaseName: String) {
        actions.move(query.id, databaseName)
    }

    private func delete() {
        actions.delete(query.id)
    }
}
