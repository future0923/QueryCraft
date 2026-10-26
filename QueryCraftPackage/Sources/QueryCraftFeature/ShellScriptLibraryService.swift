import Foundation

protocol ShellScriptLibraryServing: Sendable {
    func list(force: Bool) async throws -> [ShellScript]
    func save(original: ShellScript?, name: String, description: String, script: String) async throws -> ShellScript
    func remove(_ script: ShellScript) async throws
}

/// Desktop and MCP use the same revision-checked store. File work stays outside
/// MainActor; an unchanged inode/size/mtime avoids repeatedly decoding the library.
actor ShellScriptLibraryService: ShellScriptLibraryServing {
    let store: ShellScriptStore
    private struct Stamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date?
        let permissions: Int
        let owner: Int
    }
    private var stamp: Stamp?
    private var cached: [ShellScript]?
    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory) { store = ShellScriptStore(directory: directory) }
    func list(force: Bool = false) throws -> [ShellScript] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: store.url.path)
        let current = attributes.map { Stamp(inode: ($0[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: ($0[.size] as? NSNumber)?.uint64Value ?? 0, modified: $0[.modificationDate] as? Date,
            permissions: ($0[.posixPermissions] as? NSNumber)?.intValue ?? 0, owner: ($0[.ownerAccountID] as? NSNumber)?.intValue ?? -1) }
        if !force, current == stamp, let cached { return cached }
        let records = try store.load().sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        stamp = current; cached = records
        return records
    }
    func save(original: ShellScript?, name: String, description: String, script: String) throws -> ShellScript {
        try Task.checkCancellation()
        let saved: ShellScript
        if let original {
            saved = try store.update(id: original.id, revision: original.revision, name: name, description: description, script: script)
        } else { saved = try store.create(name: name, description: description, script: script) }
        cached = nil
        return saved
    }
    func remove(_ script: ShellScript) throws {
        try Task.checkCancellation()
        try store.remove(id: script.id, revision: script.revision)
        cached = nil
    }
}
