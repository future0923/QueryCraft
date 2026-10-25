#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation
import Observation

struct TransferTaskFolder: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var parentID: UUID?
}

struct SavedTransferTask: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var folderID: UUID?
    var configuration: DataTransferConfiguration
}

struct TransferTaskLibrary: Codable, Equatable, Sendable {
    var version = 1
    var folders: [TransferTaskFolder] = []
    var tasks: [SavedTransferTask] = []

    func validate() throws {
        guard version == 1, Set(folders.map(\.id)).count == folders.count,
              Set(tasks.map(\.id)).count == tasks.count else { throw TransferFailure("任务库格式不正确。", "Invalid task library format.") }
        for folder in folders {
            var seen: Set<UUID> = [folder.id], parent = folder.parentID
            while let id = parent {
                guard seen.insert(id).inserted, let item = folders.first(where: { $0.id == id }) else {
                    throw TransferFailure("任务文件夹存在循环或失效引用。", "Task folders contain a cycle or invalid reference.")
                }
                parent = item.parentID
            }
        }
        guard tasks.allSatisfy({ task in task.folderID == nil || folders.contains { $0.id == task.folderID } }) else {
            throw TransferFailure("任务所属文件夹不存在。", "A task references a missing folder.")
        }
        var keys: Set<String> = []
        for folder in folders {
            guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  keys.insert("f:\(folder.parentID?.uuidString ?? ""):\(folder.name.lowercased())").inserted else {
                throw TransferFailure("文件夹名称为空或重复。", "Empty or duplicate folder name.")
            }
        }
        for task in tasks {
            guard !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  keys.insert("t:\(task.folderID?.uuidString ?? ""):\(task.name.lowercased())").inserted else {
                throw TransferFailure("任务名称为空或重复。", "Empty or duplicate task name.")
            }
        }
    }
}

@MainActor @Observable
final class DataTransferLibraryStore {
    private(set) var library = TransferTaskLibrary()
    private(set) var loadError: String?
    @ObservationIgnored let url: URL

    init(url: URL = QueryCraftStorageLocation.applicationSupportDirectory.appending(path: "DataTransferTasks.json")) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let loaded = try JSONDecoder().decode(TransferTaskLibrary.self, from: data)
                try loaded.validate()
                library = loaded
            }
        } catch { loadError = error.localizedDescription }
    }

    func update(_ mutation: (inout TransferTaskLibrary) throws -> Void) throws {
        // Never overwrite an unreadable library with an empty replacement.
        guard loadError == nil else { throw TransferFailure("任务库读取失败，请修复或备份原文件后重试。", "The task library could not be read. Repair or back up the original file first.") }
        var next = library
        try mutation(&next)
        try next.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        library = next
    }

    func save(id: UUID?, name: String, folderID: UUID?, configuration: DataTransferConfiguration) throws -> UUID {
        let id = id ?? UUID()
        try update { library in
            let task = SavedTransferTask(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), folderID: folderID, configuration: configuration)
            if let index = library.tasks.firstIndex(where: { $0.id == id }) { library.tasks[index] = task }
            else { library.tasks.append(task) }
        }
        return id
    }

    func duplicate(_ task: SavedTransferTask) throws -> UUID {
        var name = task.name + "_copy1", count = 1
        let names = Set(library.tasks.filter { $0.folderID == task.folderID }.map { $0.name.lowercased() })
        while names.contains(name.lowercased()) { count += 1; name = task.name + "_copy\(count)" }
        return try save(id: nil, name: name, folderID: task.folderID, configuration: task.configuration)
    }

    func deleteFolder(_ id: UUID) throws {
        try update { library in
            var ids: Set<UUID> = [id]
            while true {
                let next = ids.union(library.folders.filter { $0.parentID.map(ids.contains) ?? false }.map(\.id))
                if next == ids { break }; ids = next
            }
            library.folders.removeAll { ids.contains($0.id) }
            library.tasks.removeAll { $0.folderID.map(ids.contains) ?? false }
        }
    }

    func moveTask(_ id: UUID, folderID: UUID?, before: UUID? = nil) throws {
        try update { library in
            guard let index = library.tasks.firstIndex(where: { $0.id == id }) else { return }
            var task = library.tasks.remove(at: index); task.folderID = folderID
            let position = before.flatMap { id in library.tasks.firstIndex { $0.id == id } } ?? library.tasks.count
            library.tasks.insert(task, at: position)
        }
    }
}
