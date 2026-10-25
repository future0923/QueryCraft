import SwiftUI

struct MobileSQLDocumentsView: View {
    @Bindable var workspace: MobileDatabaseWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: MobileSQLDocument?
    @State private var title = ""
    @State private var closing: Closing?
    private struct Closing: Identifiable {
        let id: UUID
        let snapshot: WorkspaceQueryDocumentCloseSnapshot
    }
    var body: some View {
        NavigationStack {
            List {
                Section("打开的文稿") {
                    ForEach(workspace.documents) { document in
                        HStack {
                            Button {
                                workspace.selectDocument(document.id); dismiss()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(document.title + (document.isDirty ? " •" : ""))
                                    Text(document.query.database + " · " + document.query.transactionTitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Menu {
                                Button("重命名") { title = document.title; renaming = document }
                                Button("保存文稿") { workspace.saveDocument(document.id) }
                                Button("关闭文稿", role: .destructive) {
                                    if document.isDirty || document.query.transactionState == .inTransaction { closing = .init(id: document.id, snapshot: document.closeSnapshot) }
                                    else { workspace.closeDocument(document.id) }
                                }
                            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                        }
                    }
                }
                Section("已保存查询") {
                    ForEach(workspace.savedQueries) { saved in
                        Button(saved.name) { workspace.openSavedQuery(saved); dismiss() }
                            .swipeActions { Button("删除保存的查询", role: .destructive) { workspace.deleteSavedQuery(saved.id) } }
                    }
                    if workspace.savedQueries.isEmpty { Text("保存文稿后会显示在这里。").foregroundStyle(.secondary) }
                }
                if let message = workspace.documentMessage { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
                if workspace.needsArchiveRecovery {
                    Section("恢复保存") {
                        Text("先保留原文件副本，再用当前文稿重建恢复文件；原副本可导出检查。")
                        Button("备份原文件并恢复保存") { workspace.recoverArchiveAfterBackup() }
                    }
                }
                if let backup = workspace.recoveryBackupURL { ShareLink("导出原工作区备份", item: backup) }
                Section { Text("文稿自动恢复；关闭未保存文稿会丢弃其草稿。查询结果、密码、数据改动及服务器事务不写入恢复文件。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("查询文稿").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { workspace.persistWorkspace(); dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("新建文稿", systemImage: "plus") { workspace.newDocument(); dismiss() } }
            }
            .alert("重命名文稿", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名称", text: $title)
                Button("保存") { if let renaming { workspace.renameDocument(renaming.id, title: title) }; renaming = nil }
                Button("取消", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("保存或丢弃此版本后关闭？活动事务将先回滚。", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
                Button("保存并关闭") {
                    if let closing { workspace.saveDocument(closing.id); if workspace.documents.first(where: { $0.id == closing.id })?.isDirty == false { Task { await workspace.rollbackAndCloseDocument(closing.id) } } }
                    closing = nil
                }
                Button("丢弃并关闭", role: .destructive) {
                    if let closing { Task { await workspace.rollbackAndCloseDocument(closing.id, discarding: closing.snapshot) } }
                    closing = nil
                }
            }
        }
    }
}
