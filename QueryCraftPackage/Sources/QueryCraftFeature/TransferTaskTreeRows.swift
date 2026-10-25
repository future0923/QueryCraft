import Foundation

struct TransferTaskTreeRow: Identifiable {
    let id: UUID
    let depth: Int
    let folder: TransferTaskFolder?
    let task: SavedTransferTask?
}

enum TransferTaskTreeRows {
    static func make(library: TransferTaskLibrary, search: String, collapsed: Set<UUID>) -> [TransferTaskTreeRow] {
        var result: [TransferTaskTreeRow] = []
        func append(parent: UUID?, depth: Int) {
            for folder in library.folders where folder.parentID == parent {
                let count = result.count
                result.append(.init(id: folder.id, depth: depth, folder: folder, task: nil))
                if !collapsed.contains(folder.id) || !search.isEmpty { append(parent: folder.id, depth: depth + 1) }
                if !search.isEmpty && result.count == count + 1 && !folder.name.localizedCaseInsensitiveContains(search) { result.removeLast() }
            }
            for task in library.tasks where task.folderID == parent && (search.isEmpty || task.name.localizedCaseInsensitiveContains(search)) {
                result.append(.init(id: task.id, depth: depth, folder: nil, task: task))
            }
        }
        append(parent: nil, depth: 0)
        return result
    }
}
