import SwiftUI

struct DataTransferTaskTree: View {
    @Bindable var model: DataTransferWorkbenchModel
    let newFolder: (UUID?) -> Void
    @State private var collapsed: Set<UUID> = []
    @State private var renameID: UUID?
    @State private var renameFolder = false
    @State private var renameName = ""
    @State private var showingRename = false
    @State private var deletion: UUID?
    @State private var deletingFolder = false
    @State private var showingDelete = false

    private struct Row: Identifiable {
        let id: UUID
        let depth: Int
        let folder: TransferTaskFolder?
        let task: SavedTransferTask?
    }

    private var rows: [Row] {
        let library = model.library.library, query = model.taskSearch
        var result: [Row] = []
        func append(parent: UUID?, depth: Int) {
            for folder in library.folders where folder.parentID == parent {
                let count = result.count
                result.append(.init(id: folder.id, depth: depth, folder: folder, task: nil))
                if !collapsed.contains(folder.id) || !query.isEmpty { append(parent: folder.id, depth: depth + 1) }
                if !query.isEmpty && result.count == count + 1 && !folder.name.localizedCaseInsensitiveContains(query) { result.removeLast() }
            }
            for task in library.tasks where task.folderID == parent && (query.isEmpty || task.name.localizedCaseInsensitiveContains(query)) {
                result.append(.init(id: task.id, depth: depth, folder: nil, task: task))
            }
        }
        append(parent: nil, depth: 0)
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(AppCopy.current.text("已存任务", "Saved tasks")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.requestTask(nil) } label: { Image(systemName: "plus") }.help(AppCopy.current.text("新建任务", "New task"))
                Button { newFolder(nil) } label: { Image(systemName: "folder.badge.plus") }.help(AppCopy.current.text("新建文件夹", "New folder"))
            }.buttonStyle(.borderless).padding(.horizontal, 14).frame(height: 38)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(AppCopy.current.text("搜索任务", "Search tasks"), text: $model.taskSearch).textFieldStyle(.plain)
            }.font(.callout).padding(.horizontal, 9).frame(height: 27)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
                .padding(.horizontal, 12).padding(.bottom, 8)
            List {
                ForEach(rows) { row in
                    if let folder = row.folder {
                        Button {
                            if !collapsed.insert(folder.id).inserted { collapsed.remove(folder.id) }
                        } label: {
                            HStack {
                                Image(systemName: collapsed.contains(folder.id) ? "chevron.right" : "chevron.down").font(.caption2)
                                Label(folder.name, systemImage: "folder").lineLimit(1)
                            }.padding(.leading, CGFloat(row.depth) * 12).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button(AppCopy.current.text("新建子文件夹", "New subfolder")) { newFolder(folder.id) }
                            Button(AppCopy.current.text("重命名", "Rename")) { renameID = folder.id; renameFolder = true; renameName = folder.name; showingRename = true }
                            Button(AppCopy.current.text("删除文件夹及其任务…", "Delete folder and tasks…"), role: .destructive) { deletion = folder.id; deletingFolder = true; showingDelete = true }
                        }
                        .draggable("folder:" + folder.id.uuidString)
                        .dropDestination(for: String.self) { values, _ in handleDrop(values, folderID: folder.id) }
                    } else if let task = row.task {
                        Button { model.requestTask(task) } label: {
                            HStack {
                                Label(task.name, systemImage: "arrow.left.arrow.right").lineLimit(2)
                                Spacer(minLength: 0)
                                if task.id == model.activeTaskID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }.padding(.leading, CGFloat(row.depth) * 12).padding(.vertical, 5).padding(.horizontal, 5).frame(maxWidth: .infinity, alignment: .leading)
                                .background(task.id == model.activeTaskID ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 5))
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button(AppCopy.current.text("打开", "Open")) { model.requestTask(task) }
                            Button(AppCopy.current.text("复制任务", "Duplicate task")) { perform { _ = try model.library.duplicate(task) } }
                            Button(AppCopy.current.text("重命名", "Rename")) { renameID = task.id; renameFolder = false; renameName = task.name; showingRename = true }
                            Menu(AppCopy.current.text("移动到", "Move to")) {
                                Button(AppCopy.current.text("未分组", "Unfiled")) { perform { try model.library.moveTask(task.id, folderID: nil) } }
                                ForEach(model.library.library.folders) { folder in
                                    Button(folder.name) { perform { try model.library.moveTask(task.id, folderID: folder.id) } }
                                }
                            }
                            Button(AppCopy.current.text("删除…", "Delete…"), role: .destructive) { deletion = task.id; deletingFolder = false; showingDelete = true }
                        }
                        .draggable("task:" + task.id.uuidString)
                        .dropDestination(for: String.self) { values, _ in handleDrop(values, folderID: task.folderID, before: task.id) }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .overlay(alignment: .top) {
                    if rows.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "tray").font(.system(size: 23, weight: .light)).foregroundStyle(.tertiary)
                            Text(AppCopy.current.text(model.taskSearch.isEmpty ? "还没有保存的任务" : "没有匹配的任务", model.taskSearch.isEmpty ? "No saved tasks" : "No matching tasks"))
                                .font(.callout).foregroundStyle(.secondary)
                            if model.taskSearch.isEmpty {
                                Text(AppCopy.current.text("配置传输后保存，\n下次即可直接使用。", "Save a transfer configuration\nto use it again later."))
                                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                            }
                        }.padding(.top, 48).padding(.horizontal, 12).allowsHitTesting(false)
                    }
                }
            HStack {
                Text(AppCopy.current.text("拖动排序或移入文件夹", "Drag to reorder or move into folders")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }.padding(12)
            .dropDestination(for: String.self) { values, _ in handleDrop(values, folderID: nil) }
        }.background(Color(nsColor: .windowBackgroundColor))
        .alert(AppCopy.current.text("重命名", "Rename"), isPresented: $showingRename) {
            TextField(AppCopy.current.text("名称", "Name"), text: $renameName)
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
            Button(AppCopy.current.text("保存", "Save")) {
                perform {
                    try model.library.update { library in
                        if renameFolder, let index = library.folders.firstIndex(where: { $0.id == renameID }) { library.folders[index].name = renameName.trimmingCharacters(in: .whitespacesAndNewlines) }
                        else if let index = library.tasks.firstIndex(where: { $0.id == renameID }) { library.tasks[index].name = renameName.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                }
            }
        }
        .alert(AppCopy.current.text("删除保存的任务？", "Delete saved tasks?"), isPresented: $showingDelete) {
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
            Button(AppCopy.current.text("删除", "Delete"), role: .destructive) {
                guard let deletion else { return }
                perform {
                    if deletingFolder { try model.library.deleteFolder(deletion) }
                    else { try model.library.update { $0.tasks.removeAll { $0.id == deletion } } }
                }
            }
        } message: { Text(AppCopy.current.text("仅删除保存的配置；正在运行的任务和数据库数据不受影响。", "Only saved configurations are deleted. Running transfers and database data are unaffected.")) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { model.errorMessage = error.localizedDescription }
    }
    private func handleDrop(_ values: [String], folderID: UUID?, before: UUID? = nil) -> Bool {
        guard let value = values.first, let separator = value.firstIndex(of: ":"), let id = UUID(uuidString: String(value[value.index(after: separator)...])) else { return false }
        do {
            if value.hasPrefix("task:") { try model.library.moveTask(id, folderID: folderID, before: before == id ? nil : before) }
            else if value.hasPrefix("folder:") {
                try model.library.update { library in
                    guard let index = library.folders.firstIndex(where: { $0.id == id }) else { return }
                    var folder = library.folders.remove(at: index); folder.parentID = folderID; library.folders.append(folder)
                }
            } else { return false }
            return true
        } catch { model.errorMessage = error.localizedDescription; return false }
    }
}
