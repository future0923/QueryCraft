import SwiftUI

struct MobileTransferTaskLibraryView: View {
    @Bindable var model: MobileTransferModel
    let open: (SavedTransferTask?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var collapsed: Set<UUID> = []
    @State private var editing: Editing?
    @State private var name = ""
    @State private var deleting: Editing?
    private struct Editing: Identifiable {
        var id = UUID()
        let target: UUID?
        let folder: Bool
        let parent: UUID?
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("新建任务", systemImage: "plus") { open(nil) }
                    Button("新建文件夹", systemImage: "folder.badge.plus") { name = ""; editing = .init(target: nil, folder: true, parent: nil) }
                    Picker("当前任务保存位置", selection: $model.taskFolderID) {
                        Text("未分组").tag(UUID?.none)
                        ForEach(model.library.library.folders) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                ForEach(TransferTaskTreeRows.make(library: model.library.library, search: search, collapsed: collapsed)) { row in
                    HStack {
                        if let folder = row.folder {
                            Button {
                                if !collapsed.insert(folder.id).inserted { collapsed.remove(folder.id) }
                            } label: { Label(folder.name, systemImage: collapsed.contains(folder.id) ? "folder" : "folder.fill") }
                        } else if let task = row.task {
                            Button { open(task) } label: { Label(task.name, systemImage: "arrow.left.arrow.right") }
                        }
                        Spacer()
                    }
                    .padding(.leading, CGFloat(min(row.depth, 10)) * 12)
                    .contextMenu {
                        Button("重命名") {
                            name = row.folder?.name ?? row.task?.name ?? ""
                            editing = .init(target: row.id, folder: row.folder != nil, parent: row.folder?.parentID ?? row.task?.folderID)
                        }
                        if let task = row.task {
                            Button("复制任务") { perform { _ = try model.library.duplicate(task) } }
                            Menu("移动到") {
                                Button("未分组") { perform { try model.library.moveTask(task.id, folderID: nil) } }
                                ForEach(model.library.library.folders) { folder in Button(folder.name) { perform { try model.library.moveTask(task.id, folderID: folder.id) } } }
                            }
                        }
                        if let folder = row.folder {
                            Button("新建子文件夹") { name = ""; editing = .init(target: nil, folder: true, parent: folder.id) }
                            Menu("移动文件夹") {
                                Button("根目录") { moveFolder(folder, to: nil) }
                                ForEach(model.library.library.folders.filter { $0.id != folder.id }) { parent in Button(parent.name) { moveFolder(folder, to: parent.id) } }
                            }
                        }
                        Button("删除", role: .destructive) { deleting = .init(target: row.id, folder: row.folder != nil, parent: nil) }
                    }
                    .draggable((row.folder == nil ? "task:" : "folder:") + row.id.uuidString)
                    .dropDestination(for: String.self) { values, _ in
                        guard let value = values.first, value.hasPrefix("task:"), let id = UUID(uuidString: String(value.dropFirst(5))) else { return false }
                        do {
                            try model.library.moveTask(id, folderID: row.folder?.id ?? row.task?.folderID, before: row.task?.id == id ? nil : row.task?.id)
                            return true
                        } catch { model.message = error.localizedDescription; return false }
                    }
                }
                if let error = model.library.loadError { Text(error).foregroundStyle(.red) }
                if let message = model.message { Text(message).foregroundStyle(.red) }
            }
            .onChange(of: model.library.library) { _, _ in model.libraryDidChange() }
            .searchable(text: $search, prompt: "查找任务或文件夹")
            .navigationTitle("传输配置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert(editing?.target == nil ? "新建文件夹" : "重命名", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("名称", text: $name)
                Button("取消", role: .cancel) { editing = nil }
                Button("保存") {
                    guard let editing else { return }
                    perform {
                        try model.library.update { library in
                            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if editing.folder {
                                if let index = library.folders.firstIndex(where: { $0.id == editing.target }) { library.folders[index].name = title }
                                else { library.folders.append(.init(name: title, parentID: editing.parent)) }
                            } else if let index = library.tasks.firstIndex(where: { $0.id == editing.target }) { library.tasks[index].name = title }
                        }
                    }
                    self.editing = nil
                }
            }
            .confirmationDialog("删除保存的配置？文件夹中的任务也会删除，数据库和运行中任务不受影响。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let deleting, let id = deleting.target {
                        perform {
                            if deleting.folder { try model.library.deleteFolder(id) }
                            else { try model.library.update { $0.tasks.removeAll { $0.id == id } } }
                        }
                    }
                    deleting = nil
                }
            }
        }
    }
    private func moveFolder(_ folder: TransferTaskFolder, to parent: UUID?) {
        perform { try model.library.update { library in
            if let index = library.folders.firstIndex(where: { $0.id == folder.id }) { library.folders[index].parentID = parent }
        } }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { model.message = error.localizedDescription } }
}
