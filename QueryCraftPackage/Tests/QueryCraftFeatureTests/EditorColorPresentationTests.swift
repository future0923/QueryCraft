import AppKit
@testable import CodeEditTextView
@testable import CodeEditSourceEditor
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite(.serialized)
struct EditorColorPresentationTests {
    @Test
    func changingThemeKeepsTextSelectionAndUndoState() {
        let source = "SELECT id FROM users WHERE active = TRUE;"
        let controller = TextViewController(
            string: source, language: .sql,
            configuration: .init(appearance: .init(
                theme: WorkspaceEditorTheme.make(for: .aqua),
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false
            )), cursorPositions: [], highlightProviders: [WorkspaceSQLLanguageService()]
        )
        controller.loadViewIfNeeded()
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 7, length: 2))
        let selection = controller.textView.selectedRange()
        let undoManager = controller.textView.undoManager
        let canUndo = undoManager?.canUndo
        var settings = EditorColorSettings()
        settings.light.setHex("#123456", for: .property)
        controller.configuration.appearance.theme = WorkspaceEditorTheme.make(for: .aqua, settings: settings)
        #expect(controller.text == source)
        #expect(controller.textView.selectedRange() == selection)
        #expect(controller.textView.undoManager === undoManager)
        #expect(controller.textView.undoManager?.canUndo == canUndo)
        #expect(EditorHexColor.hex(controller.attributesFor(.property)[.foregroundColor] as! NSColor) == "#123456")
    }

    @Test
    func systemCursorUpdatesItsColor() throws {
        let textView = TextView(string: "SELECT 1", font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        let selection = try #require(textView.selectionManager.textSelections.first)
        let indicator = NSTextInsertionIndicator(frame: .zero)
        selection.view = indicator
        textView.selectionManager.insertionPointColor = EditorHexColor.color("#123456")
        #expect(EditorHexColor.hex(indicator.color) == "#123456")
    }

    @Test
    func jsonKeysValuesAndPunctuationUseDistinctCaptures() async throws {
        let json = #"{"name":"hello\nworld","enabled":true,"count":42,"empty":null}"#
        let provider = TreeSitterClient()
        let controller = TextViewController(
            string: json, language: .json,
            configuration: .init(appearance: .init(
                theme: WorkspaceEditorTheme.make(for: .aqua),
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false
            )), cursorPositions: [], highlightProviders: [provider]
        )
        controller.loadViewIfNeeded()
        let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: controller.textView,
                                        range: NSRange(location: 0, length: (json as NSString).length)) {
                continuation.resume(with: $0)
            }
        }
        let styles = StyledRangeContainer(documentLength: (json as NSString).length, providers: [0])
        styles.applyHighlightResult(provider: 0, highlights: highlights,
                                    rangeToHighlight: NSRange(location: 0, length: (json as NSString).length))
        for (token, expected) in [("\"name\"", CaptureName.property), ("hello", .string), ("\\n", .typeAlternate),
                                  ("true", .boolean), ("42", .number), ("null", .boolean), ("{", .punctuation)] {
            let range = (json as NSString).range(of: token)
            #expect(styles.runsIn(range: range).first?.value?.capture == expected, "\(token)")
        }
    }

    @Test(arguments: EditorColorMode.allCases)
    func settingsSheetRendersWithoutPresentingAWindow(_ mode: EditorColorMode) async throws {
        let suite = "EditorColorPresentation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = EditorColorsSettingsView(preferences: ApplicationPreferences(userDefaults: defaults), mode: mode)
            .environment(\.colorScheme, mode == .dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let appearance = try #require(NSAppearance(named: mode.appearanceName))
        window.appearance = appearance
        host.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 960)
        #expect(host.fittingSize.height <= 700)
        if let directory = ProcessInfo.processInfo.environment["QUERYCRAFT_COLOR_SNAPSHOTS"] {
            let context = try #require(CGContext(
                data: nil, width: 1920, height: 1400, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.scaleBy(x: 2, y: 2)
            context.setFillColor(NSColor.windowBackgroundColor.resolved(for: appearance).cgColor)
            context.fill(host.bounds)
            context.translateBy(x: 0, y: host.bounds.height)
            context.scaleBy(x: 1, y: -1)
            appearance.performAsCurrentDrawingAppearance {
                host.layer?.render(in: context)
            }
            let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("editor-colors-\(mode.rawValue).png"))
        }
    }
}
