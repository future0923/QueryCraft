import AppKit
import Observation

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

/// The panel callback and tests share the same cancellation and file IO path.
@MainActor
enum EditorThemeFiles {
    static func read(response: NSApplication.ModalResponse, url: URL?) throws -> SavedEditorTheme? {
        guard response == .OK, let url else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Bound the read itself, including files replaced after the picker returned.
        let data = try file.read(upToCount: 256 * 1024 + 1) ?? Data()
        return try EditorThemeArchive.read(data)
    }

    static func write(response: NSApplication.ModalResponse, url: URL?, settings: EditorColorSettings) throws {
        guard response == .OK, let url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = String(url.deletingPathExtension().lastPathComponent.prefix(80))
        try EditorThemeArchive(name: name, settings: settings).data().write(to: url, options: .atomic)
    }

    static func append(_ theme: SavedEditorTheme, to preferences: ApplicationPreferences) {
        var theme = theme
        let names = Set(preferences.editorThemes.map(\.name))
        let base = String(theme.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        theme.name = base
        var suffix = 2
        while names.contains(theme.name) {
            let ending = " (\(suffix))"
            theme.name = String(base.prefix(80 - ending.count)) + ending
            suffix += 1
        }
        preferences.editorThemes.append(theme)
    }
}

@MainActor @Observable
final class EditorColorEditingSession {
    let original: EditorColorSettings
    private var past: [EditorColorSettings] = []
    private var future: [EditorColorSettings] = []
    private var continuousKey: String?
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    init(settings: EditorColorSettings) { original = settings }

    func finishContinuousChange() { continuousKey = nil }

    func change(_ preferences: ApplicationPreferences, key: String? = nil,
                _ mutation: (inout EditorColorSettings) -> Void) {
        var next = preferences.editorColors
        mutation(&next)
        guard next != preferences.editorColors else { return }
        if key == nil || key != continuousKey {
            past.append(preferences.editorColors)
            if past.count > 100 { past.removeFirst() }
        }
        continuousKey = key
        future.removeAll()
        preferences.editorColors = next
    }

    func undo(_ preferences: ApplicationPreferences) {
        guard let previous = past.popLast() else { return }
        finishContinuousChange()
        future.append(preferences.editorColors)
        preferences.editorColors = previous
    }

    func redo(_ preferences: ApplicationPreferences) {
        guard let next = future.popLast() else { return }
        finishContinuousChange()
        past.append(preferences.editorColors)
        preferences.editorColors = next
    }

    func restore(_ preferences: ApplicationPreferences) { change(preferences) { $0 = original } }
}

enum EditorColorReadability {
    struct Result: Identifiable {
        let role: EditorColorRole
        let background: EditorColorRole
        let ratio: Double
        let minimum: Double
        var id: String { role.rawValue + background.rawValue }
    }

    static func ratio(_ foreground: NSColor, _ background: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.sRGB)!
            func channel(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func checks(settings: EditorColorSettings, mode: EditorColorMode) -> [Result] {
        let palette = settings[mode]
        func color(_ role: EditorColorRole) -> NSColor { EditorHexColor.color(palette.hex(for: role, mode: mode)) }
        func selection(over background: NSColor, inactive: Bool) -> NSColor {
            var fill = color(.selection)
            if inactive, let device = fill.usingColorSpace(.deviceRGB) {
                // Match TextSelectionManager's unfocused grayscale selection.
                let gray = 0.299 * device.redComponent + 0.587 * device.greenComponent + 0.114 * device.blueComponent
                fill = NSColor(white: gray, alpha: 1).usingColorSpace(.sRGB) ?? fill
            }
            let opacity = mode == .dark ? 0.35 : 0.22
            return NSColor(srgbRed: fill.redComponent * opacity + background.redComponent * (1 - opacity),
                           green: fill.greenComponent * opacity + background.greenComponent * (1 - opacity),
                           blue: fill.blueComponent * opacity + background.blueComponent * (1 - opacity), alpha: 1)
        }
        var results: [Result] = []
        for role in EditorColorRole.syntax {
            for background in [EditorColorRole.background, .currentLine] {
                results.append(.init(role: role, background: background, ratio: ratio(color(role), color(background)), minimum: 4.5))
                for inactive in [false, true] {
                    results.append(.init(role: role, background: .selection,
                                         ratio: ratio(color(role), selection(over: color(background), inactive: inactive)), minimum: 4.5))
                }
            }
        }
        for (role, background, minimum) in [(EditorColorRole.lineNumber, EditorColorRole.background, 4.5),
                                           (.currentLineNumber, .currentLine, 4.5), (.cursor, .background, 3.0),
                                           (.cursor, .currentLine, 3.0), (.searchText, .searchCurrent, 4.5),
                                           (.text, .searchMatch, 4.5)] {
            results.append(.init(role: role, background: background, ratio: ratio(color(role), color(background)), minimum: minimum))
        }
        // Keep the lowest selection contrast across both backgrounds and focus states.
        return Dictionary(grouping: results, by: \.id).values.compactMap { $0.min { $0.ratio < $1.ratio } }
            .sorted { $0.ratio < $1.ratio }
    }
}
