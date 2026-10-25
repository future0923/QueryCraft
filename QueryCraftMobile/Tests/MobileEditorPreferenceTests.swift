import Foundation
import Testing
import UIKit
@testable import QueryCraftMobileProof

@MainActor struct MobileEditorPreferenceTests {
    @Test func independentPalettesFontIndentCompletionAndFormattingPersist() async throws {
        let suite = "MobileEditorPreferenceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MobileEditorPreferences(defaults: defaults)
        preferences.colors[.light].apply(.ocean); preferences.colors[.light].setHex("12ab34", for: .keyword)
        preferences.colors[.dark].apply(.soft); preferences.fontSize = 17
        preferences.indentationStyle = .tabs; preferences.indentationWidth = 8
        preferences.completionKey = .tab; preferences.keywordCase = .lowercase
        let restored = MobileEditorPreferences(defaults: defaults)
        #expect(restored.colors == preferences.colors); #expect(restored.font.pointSize == 17)
        #expect(restored.indentationUnit == "\t"); #expect(restored.completionKey == .tab)
        #expect(!EditorPreferenceRules.acceptsReturn(restored.completionKey)); #expect(EditorPreferenceRules.acceptsTab(restored.completionKey))
        let source = SQLSourceSnapshot(revision: .init(1), text: "SELECT id FROM users WHERE id=1")
        let edit = try #require(try await MobileSQLFormatter(options: restored.formattingOptions).edit(for: .document, source: source, selection: .init(location: 0, length: 0)))
        #expect(edit.replacement.contains("select")); #expect(!edit.replacement.contains("SELECT"))
        restored.fontSize = 100; #expect(restored.fontSize == 18)
        restored.indentationWidth = 3; #expect(restored.indentationWidth == 4)
        restored.reset(); #expect(restored.indentationUnit == "    "); #expect(restored.completionKey == .returnOrTab)
    }
    @Test func desktopThemeArchiveImportsExactlyAndInvalidFileDoesNotChangeSettings() throws {
        let suite = "MobileEditorThemeTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MobileEditorPreferences(defaults: defaults)
        var settings = EditorColorSettings(); settings[.light].apply(.ocean); settings[.dark].apply(.soft)
        settings[.dark].boldKeywords = false; settings[.light].setHex("#ABCDEF", for: .searchCurrent)
        let data = try EditorThemeArchive(name: "Shared theme", settings: settings).data()
        try preferences.importTheme(data); try preferences.importTheme(data)
        #expect(preferences.themes.map(\.name) == ["Shared theme", "Shared theme (2)"])
        let imported = try EditorThemeArchive.read(data)
        #expect(preferences.colors == imported.settings)
        let before = preferences.colors
        #expect(throws: (any Error).self) { try preferences.importTheme(Data("{}".utf8)) }
        #expect(preferences.colors == before)
        #expect(EditorHexColor.hex(EditorHexColor.color("#ABCDEF")) == "#ABCDEF")
    }
    @Test func continuousColorChangesShareDesktopUndoGrouping() {
        var history = EditorColorChangeHistory(), initial = EditorColorSettings(), changed = initial
        changed[.light].setHex("#123456", for: .keyword)
        history.record(from: initial, to: changed, key: "light.keyword")
        var final = changed; final[.light].setHex("#654321", for: .keyword)
        history.record(from: changed, to: final, key: "light.keyword")
        #expect(history.undo(current: final) == initial)
        #expect(history.redo(current: initial) == final)
        initial[.dark].apply(.soft)
        history.record(from: final, to: initial)
        #expect(!history.canRedo)
    }

}
