import Foundation

struct MobileQueryHistoryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let profileID: UUID
    let database: String
    let sql: String
    let date: Date
}

struct MobileLibraryState: Codable {
    var version = 1
    var profiles: [MobileConnectionProfile] = []
    var history: [MobileQueryHistoryItem] = []
}

@MainActor
protocol MobileLibraryPersisting {
    func load() throws -> MobileLibraryState
    func write(_ state: MobileLibraryState) throws
}

@MainActor
struct MobileLibraryRepository: MobileLibraryPersisting {
    let file: URL

    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory
            .appending(path: "QueryCraftMobile", directoryHint: .isDirectory).appending(path: "connections.json")
    }

    func load() throws -> MobileLibraryState {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard (size?.intValue ?? Int.max) <= 2_097_152 else { throw LibraryError.invalidFile }
        let state = try JSONDecoder().decode(MobileLibraryState.self, from: Data(contentsOf: file))
        guard state.version == 1, Set(state.profiles.map(\.id)).count == state.profiles.count,
              state.profiles.allSatisfy({ !$0.name.isEmpty && !$0.host.isEmpty && (1...65535).contains($0.port) }) else {
            throw LibraryError.invalidFile
        }
        return state
    }

    func write(_ state: MobileLibraryState) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= 2_097_152 else { throw LibraryError.invalidFile }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    private enum LibraryError: LocalizedError {
        case invalidFile
        var errorDescription: String? { "连接文件格式或大小异常，原文件已保留。请检查文件后重试。" }
    }
}
