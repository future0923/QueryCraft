import AppKit
import Observation

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
    private var history = EditorColorChangeHistory()
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    init(settings: EditorColorSettings) { original = settings }

    func finishContinuousChange() { history.finishContinuousChange() }

    func change(_ preferences: ApplicationPreferences, key: String? = nil,
                _ mutation: (inout EditorColorSettings) -> Void) {
        var next = preferences.editorColors
        mutation(&next)
        guard next != preferences.editorColors else { return }
        history.record(from: preferences.editorColors, to: next, key: key)
        preferences.editorColors = next
    }

    func undo(_ preferences: ApplicationPreferences) {
        if let previous = history.undo(current: preferences.editorColors) { preferences.editorColors = previous }
    }

    func redo(_ preferences: ApplicationPreferences) {
        if let next = history.redo(current: preferences.editorColors) { preferences.editorColors = next }
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

    /// WCAG 2 ratios overstate legibility on dark backgrounds, so dark thresholds are higher for comparable perceived contrast.
    enum Tier {
        case content, syntax, subtle, faint, cursor

        func minimum(for mode: EditorColorMode) -> Double {
            switch (self, mode) {
            case (.content, .light): 4.5
            case (.content, .dark): 7
            case (.syntax, .light): 2
            case (.syntax, .dark): 4.5
            case (.subtle, .light): 1.7
            case (.subtle, .dark): 3.5
            case (.faint, .light): 1.4
            case (.faint, .dark): 3
            case (.cursor, _): 3
            }
        }

        /// Selection and search highlights are transient overlays, so text beneath them is held one tier lower.
        var overlay: Self {
            switch self {
            case .content: .syntax
            case .syntax: .subtle
            case .subtle, .faint: .faint
            case .cursor: .cursor
            }
        }
    }

    static func tier(for role: EditorColorRole) -> Tier {
        switch role {
        case .text, .currentLineNumber, .searchText: .content
        case .comment, .punctuation, .lineNumber: .subtle
        case .cursor: .cursor
        default: .syntax
        }
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
        func selection(inactive: Bool) -> NSColor {
            let background = color(.background)
            var fill = color(.selection)
            if inactive, let device = fill.usingColorSpace(.deviceRGB) {
                // Match TextSelectionManager's unfocused grayscale selection.
                let gray = 0.299 * device.redComponent + 0.587 * device.greenComponent + 0.114 * device.blueComponent
                fill = NSColor(white: gray, alpha: 1).usingColorSpace(.sRGB) ?? fill
            }
            // Mirrors WorkspaceEditorTheme's translucent selection fill.
            let opacity = mode == .dark ? 0.35 : 0.22
            return NSColor(srgbRed: fill.redComponent * opacity + background.redComponent * (1 - opacity),
                           green: fill.greenComponent * opacity + background.greenComponent * (1 - opacity),
                           blue: fill.blueComponent * opacity + background.blueComponent * (1 - opacity), alpha: 1)
        }
        var results: [Result] = []
        func check(_ role: EditorColorRole, on background: EditorColorRole, _ tier: Tier, ratio value: Double? = nil) {
            results.append(.init(role: role, background: background, ratio: value ?? ratio(color(role), color(background)),
                                 minimum: tier.minimum(for: mode)))
        }
        for role in EditorColorRole.syntax {
            let roleTier = tier(for: role)
            check(role, on: .background, roleTier)
            check(role, on: .currentLine, roleTier)
            // A non-empty selection replaces the current-line highlight, so only the plain background lies beneath it.
            let selected = [false, true].map { ratio(color(role), selection(inactive: $0)) }.min() ?? 1
            check(role, on: .selection, roleTier.overlay, ratio: selected)
        }
        check(.lineNumber, on: .background, tier(for: .lineNumber))
        check(.currentLineNumber, on: .currentLine, tier(for: .currentLineNumber))
        check(.cursor, on: .background, .cursor)
        check(.cursor, on: .currentLine, .cursor)
        check(.searchText, on: .searchCurrent, tier(for: .searchText))
        check(.text, on: .searchMatch, tier(for: .text).overlay)
        return results.sorted { $0.ratio / $0.minimum < $1.ratio / $1.minimum }
    }
}
