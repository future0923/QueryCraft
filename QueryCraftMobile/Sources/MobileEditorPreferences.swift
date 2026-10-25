import Foundation
import Observation
import UIKit

@MainActor @Observable
final class MobileEditorPreferences {
    static let shared = MobileEditorPreferences()
    @ObservationIgnored private let defaults: UserDefaults
    var colors: EditorColorSettings { didSet { save(colors, EditorPreferenceKey.colors) } }
    var themes: [SavedEditorTheme] { didSet { save(themes, EditorPreferenceKey.themes) } }
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: EditorPreferenceKey.fontFamily) } }
    var fontSize: Double { didSet {
        let value = fontSize.isFinite ? min(18, max(11, fontSize.rounded())) : 15
        if fontSize != value { fontSize = value }
        defaults.set(value, forKey: EditorPreferenceKey.fontSize)
    } }
    var indentationStyle: EditorIndentationStyle { didSet { defaults.set(indentationStyle.rawValue, forKey: EditorPreferenceKey.indentationStyle) } }
    var indentationWidth: Int { didSet {
        if !EditorPreferenceRules.indentationWidths.contains(indentationWidth) { indentationWidth = 4 }
        defaults.set(indentationWidth, forKey: EditorPreferenceKey.indentationWidth)
    } }
    var completionKey: EditorCompletionKey { didSet { defaults.set(completionKey.rawValue, forKey: EditorPreferenceKey.completionKey) } }
    var keywordCase: SQLKeywordCase { didSet { defaults.set(keywordCase.rawValue, forKey: EditorPreferenceKey.keywordCase) } }
    var ansiQuoteConnections: Set<String> { didSet { defaults.set(Array(ansiQuoteConnections).sorted(), forKey: EditorPreferenceKey.ansiQuoteConnections) } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value(_ name: String) -> String? { defaults.string(forKey: name) }
        colors = EditorColorSettings.load(defaults.data(forKey: EditorPreferenceKey.colors))
        themes = defaults.data(forKey: EditorPreferenceKey.themes).flatMap { try? JSONDecoder().decode([SavedEditorTheme].self, from: $0) } ?? []
        fontFamily = value(EditorPreferenceKey.fontFamily) ?? ""
        let size = defaults.object(forKey: EditorPreferenceKey.fontSize) as? Double ?? 15
        fontSize = size.isFinite ? min(18, max(11, size.rounded())) : 15
        indentationStyle = value(EditorPreferenceKey.indentationStyle).flatMap(EditorIndentationStyle.init(rawValue:)) ?? .spaces
        let width = defaults.integer(forKey: EditorPreferenceKey.indentationWidth)
        indentationWidth = EditorPreferenceRules.indentationWidths.contains(width) ? width : 4
        completionKey = value(EditorPreferenceKey.completionKey).flatMap(EditorCompletionKey.init(rawValue:)) ?? .returnOrTab
        keywordCase = value(EditorPreferenceKey.keywordCase).flatMap(SQLKeywordCase.init(rawValue:)) ?? .uppercase
        ansiQuoteConnections = Set(defaults.stringArray(forKey: EditorPreferenceKey.ansiQuoteConnections) ?? [])
    }
    private func save<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: name) }
    }
    var indentationUnit: String { EditorPreferenceRules.indentationUnit(style: indentationStyle, width: indentationWidth) }
    var formattingOptions: SQLFormattingOptions { .init(keywordCase: keywordCase, indentationUnit: indentationUnit) }
    var font: UIFont {
        if !fontFamily.isEmpty, let name = UIFont.fontNames(forFamilyName: fontFamily).first,
           let font = UIFont(name: name, size: fontSize) { return font }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    func reset() {
        colors = .init(); fontFamily = ""; fontSize = 15
        indentationStyle = .spaces; indentationWidth = 4; completionKey = .returnOrTab; keywordCase = .uppercase
    }
    func importTheme(_ data: Data) throws {
        var theme = try EditorThemeArchive.read(data)
        let base = theme.name, names = Set(themes.map(\.name))
        var suffix = 2
        while names.contains(theme.name) {
            let end = " (\(suffix))"; theme.name = String(base.prefix(80 - end.count)) + end; suffix += 1
        }
        themes.append(theme); colors = theme.settings
    }
}
