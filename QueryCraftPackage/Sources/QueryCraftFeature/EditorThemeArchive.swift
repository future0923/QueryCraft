#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

struct SavedEditorTheme: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var settings: EditorColorSettings
}

/// A strict interchange format, independent of the forgiving preferences decoder.
struct EditorThemeArchive: Codable {
    struct Palette: Codable {
        let colors: [String: String]
        let boldKeywords: Bool
        let italicComments: Bool
    }
    let format: String
    let version: Int
    let name: String
    let light: Palette
    let dark: Palette

    init(name: String, settings: EditorColorSettings) {
        format = "QueryCraft.EditorTheme"
        version = 1
        self.name = name
        func palette(_ mode: EditorColorMode) -> Palette {
            .init(colors: Dictionary(uniqueKeysWithValues: EditorColorRole.allCases.map {
                ($0.rawValue, settings[mode].hex(for: $0, mode: mode))
            }), boldKeywords: settings[mode].boldKeywords, italicComments: settings[mode].italicComments)
        }
        light = palette(.light)
        dark = palette(.dark)
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func read(_ data: Data) throws -> SavedEditorTheme {
        guard data.count <= 256 * 1024 else { throw ArchiveError.invalid }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.format == "QueryCraft.EditorTheme", archive.version == 1,
              !archive.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              archive.name.count <= 80 else { throw ArchiveError.invalid }
        var settings = EditorColorSettings()
        for (mode, palette) in [(EditorColorMode.light, archive.light), (.dark, archive.dark)] {
            guard Set(palette.colors.keys) == Set(EditorColorRole.allCases.map(\.rawValue)) else { throw ArchiveError.invalid }
            for role in EditorColorRole.allCases {
                guard let raw = palette.colors[role.rawValue], let hex = EditorHexColor.normalized(raw) else {
                    throw ArchiveError.invalid
                }
                settings[mode].setHex(hex, for: role)
            }
            settings[mode].boldKeywords = palette.boldKeywords
            settings[mode].italicComments = palette.italicComments
        }
        return SavedEditorTheme(name: archive.name.trimmingCharacters(in: .whitespacesAndNewlines), settings: settings)
    }

    enum ArchiveError: LocalizedError {
        case invalid
        var errorDescription: String? {
            AppCopy.current.text("主题文件无效、版本不支持或颜色不完整。", "Invalid theme, unsupported version, or incomplete colors.")
        }
    }
}
