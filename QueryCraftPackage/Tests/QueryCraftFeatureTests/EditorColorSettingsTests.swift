import AppKit
@testable import CodeEditSourceEditor
import Testing
@testable import QueryCraftFeature

struct EditorColorSettingsTests {
    @Test(arguments: EditorColorPreset.allCases, EditorColorMode.allCases)
    func presetsHaveCompleteOpaqueColors(_ preset: EditorColorPreset, _ mode: EditorColorMode) {
        let colors = preset.colors(for: mode)
        #expect(colors.count == EditorColorRole.allCases.count)
        for role in EditorColorRole.allCases {
            #expect(colors[role].flatMap(EditorHexColor.normalized) == colors[role])
            #expect(colors[role] != nil)
        }
    }

    @MainActor @Test
    func lightAndDarkPersistIndependentlyAndResetIndividually() throws {
        let suite = "EditorColorSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        preferences.editorColors[.light].apply(.ocean)
        preferences.editorColors[.light].setHex("12Ab34", for: .keyword)
        preferences.editorColors[.dark].apply(.soft)
        preferences.editorColors[.dark].setHex("#AABBCC", for: .function)
        let restored = ApplicationPreferences(userDefaults: defaults)
        #expect(restored.editorColors == preferences.editorColors)
        #expect(restored.editorColors[.light].hex(for: .keyword, mode: .light) == "#12AB34")
        let dark = restored.editorColors.dark
        restored.editorColors[.light].reset(.keyword)
        #expect(restored.editorColors[.light].hex(for: .keyword, mode: .light) == EditorColorPreset.ocean.colors(for: .light)[.keyword])
        restored.editorColors[.light].apply(.classic)
        #expect(restored.editorColors.dark == dark)
        restored.resetEditor()
        #expect(restored.editorColors == EditorColorSettings())
    }

    @Test
    func invalidAndUnknownStoredValuesFallBack() {
        #expect(EditorColorSettings.load(Data("broken".utf8)) == EditorColorSettings())
        let data = Data(##"{"light":{"presetID":"future","overrides":{"keyword":"#GGGGGG","string":"#123456"}},"dark":{"presetID":"ocean","overrides":{}}}"##.utf8)
        let settings = EditorColorSettings.load(data)
        #expect(settings.light.preset == .classic)
        #expect(settings.dark.preset == .ocean)
        #expect(settings.light.hex(for: .keyword, mode: .light) == EditorColorPreset.classic.colors(for: .light)[.keyword])
        #expect(settings.light.hex(for: .string, mode: .light) == "#123456")
    }

    @Test
    func damagedAppearanceDoesNotDiscardTheOtherPalette() {
        let data = Data(##"{"light":false,"dark":{"presetID":"ocean","overrides":{"function":"#123456"}}}"##.utf8)
        let settings = EditorColorSettings.load(data)
        #expect(settings.light == EditorColorPalette())
        #expect(settings.dark.preset == .ocean)
        #expect(settings.dark.hex(for: .function, mode: .dark) == "#123456")
        #expect(EditorColorSettings.load(Data(#"{"light":{"presetID":"soft"}}"#.utf8)).light.preset == .soft)
    }

    @Test(arguments: ["#ABC", "#12345678", "#GGGGGG", "", "１２３４５６"])
    func rejectsInvalidHex(_ hex: String) {
        #expect(EditorHexColor.normalized(hex) == nil)
        var palette = EditorColorPalette()
        palette.setHex(hex, for: .text)
        #expect(palette.overrides.isEmpty)
    }

    @Test(arguments: EditorColorMode.allCases)
    func semanticCapturesHaveIndependentColors(_ mode: EditorColorMode) {
        let roles: [(EditorColorRole, CaptureName)] = [
            (.keyword, .keyword), (.object, .type), (.property, .property),
            (.function, .function), (.type, .typeBuiltin), (.string, .string),
            (.number, .number), (.boolean, .boolean), (.variable, .variable),
            (.parameter, .parameter), (.attribute, .typeAlternate),
            (.operator, .operator), (.punctuation, .punctuation), (.comment, .comment)
        ]
        for (role, capture) in roles {
            var settings = EditorColorSettings()
            settings[mode].setHex("#123456", for: role)
            let theme = WorkspaceEditorTheme.make(for: mode.appearanceName, settings: settings)
            #expect(EditorHexColor.hex(theme.colorFor(capture)) == "#123456")
            for (otherRole, otherCapture) in roles where otherRole != role {
                #expect(EditorHexColor.hex(theme.colorFor(otherCapture)) != "#123456")
            }
        }
    }
}
