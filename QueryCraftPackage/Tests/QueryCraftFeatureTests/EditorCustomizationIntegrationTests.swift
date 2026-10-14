import AppKit
import CodeEditTextView
import SwiftUI
import Testing
@testable import CodeEditSourceEditor
@testable import QueryCraftFeature

@MainActor @Suite(.serialized)
struct EditorCustomizationIntegrationTests {
    @Test(arguments: [960, 1080], [EditorColorMode.light, .dark])
    func sideBySideLayoutFitsBothLanguages(_ width: Int, _ mode: EditorColorMode) async throws {
        for language in [ApplicationLanguage.english, .simplifiedChinese] {
            let suite = "ColorLayout.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let height = 700
            let view = EditorColorsSettingsView(preferences: ApplicationPreferences(userDefaults: defaults), mode: mode, language: language)
                .environment(\.colorScheme, mode == .dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: mode.appearanceName)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            func textView(in view: NSView) -> TextView? {
                (view as? TextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
            }
            let editor = try #require(textView(in: host))
            let editorFrame = editor.convert(editor.bounds, to: host)
            #expect(editorFrame.midX < CGFloat(width) / 2)
            #expect(editorFrame.width > 350)
            #expect(editorFrame.height > 450)
            editor.layoutManager.layoutLines()
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: editor)
            for _ in 0..<40 {
                let color = editor.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                if color.flatMap(EditorHexColor.hex) == EditorColorSettings()[mode].hex(for: .comment, mode: mode) { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(EditorHexColor.hex(editor.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor)
                    == EditorColorSettings()[mode].hex(for: .comment, mode: mode))
            editor.layoutManager.invalidateLayoutForRect(editor.visibleRect)
            editor.layoutManager.layoutLines(in: editor.visibleRect)
            host.displayIfNeeded()
            if let nativeBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: nativeBitmap)
            }
            #expect(host.frame.width == CGFloat(width))
            #expect(host.frame.height == CGFloat(height))
            if let directory = ProcessInfo.processInfo.environment["QUERYCRAFT_COLOR_SNAPSHOTS"] {
                let appearance = try #require(window.appearance)
                let context = try #require(CGContext(data: nil, width: width * 2, height: height * 2,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x: 2, y: 2)
                context.setFillColor(NSColor.windowBackgroundColor.resolved(for: appearance).cgColor)
                context.fill(host.bounds)
                context.translateBy(x: 0, y: host.bounds.height)
                context.scaleBy(x: 1, y: -1)
                appearance.performAsCurrentDrawingAppearance { host.layer?.render(in: context) }
                let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("customization-\(language.rawValue)-\(mode.rawValue)-\(width).png"))
            }
        }
    }

    @Test func threeMountedEditorsObservePaletteAndKeepTextSelectionsAndUndo() async throws {
        let suite = "ColorMounted.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        let kinds: [EditorColorPreviewKind] = [.mysql, .json, .elasticsearch]
        let probes = kinds.map { _ in Probe() }
        let windows = zip(kinds, probes).map { kind, probe in
            let host = NSHostingView(rootView: MountedEditor(preferences: preferences, kind: kind, probe: probe))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return window
        }
        defer { for window in windows { window.contentView = nil } }
        try await Task.sleep(for: .milliseconds(150))
        let controllers = try probes.map { try #require($0.controller) }
        for controller in controllers {
            let undo = try #require(controller.textView.undoManager)
            undo.beginUndoGrouping()
            controller.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: " ")
            undo.endUndoGrouping()
            controller.textView.selectionManager.setSelectedRange(NSRange(location: 1, length: 2))
        }
        let texts = controllers.map(\.text)
        preferences.editorColors.light.setHex("#123456", for: .property)
        for _ in 0..<30 {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            if controllers.allSatisfy({ EditorHexColor.hex($0.attributesFor(.property)[.foregroundColor] as! NSColor) == "#123456" }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        for (index, controller) in controllers.enumerated() {
            #expect(EditorHexColor.hex(controller.attributesFor(.property)[.foregroundColor] as! NSColor) == "#123456")
            #expect(controller.text == texts[index])
            #expect(controller.textView.selectedRange() == NSRange(location: 1, length: 2))
            let undo = try #require(controller.textView.undoManager)
            #expect(undo.canUndo)
            undo.undo()
            #expect(controller.text == kinds[index].source)
            undo.redo()
            #expect(controller.text == texts[index])
        }
        #expect(ApplicationPreferences(userDefaults: defaults).editorColors.light.hex(for: .property, mode: .light) == "#123456")
    }

    private final class Probe: TextViewCoordinator {
        weak var controller: TextViewController?
        func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    }
    private struct MountedEditor: View {
        @Bindable var preferences: ApplicationPreferences
        let kind: EditorColorPreviewKind
        let probe: Probe
        @State private var source: String
        @State private var state = SourceEditorState()
        @State private var provider: EditorPreviewHighlighter
        init(preferences: ApplicationPreferences, kind: EditorColorPreviewKind, probe: Probe) {
            self.preferences = preferences; self.kind = kind; self.probe = probe
            _source = State(initialValue: kind.source)
            _provider = State(initialValue: EditorPreviewHighlighter(kind: kind))
        }
        var body: some View {
            SourceEditor($source, language: kind.language,
                configuration: .init(appearance: .init(theme: WorkspaceEditorTheme.make(for: .aqua, settings: preferences.editorColors),
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false)),
                state: $state, highlightProviders: [provider], coordinators: [probe])
        }
    }
}
