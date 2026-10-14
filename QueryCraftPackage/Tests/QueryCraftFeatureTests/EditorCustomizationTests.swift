import AppKit
import SwiftUI
import Testing
@testable import CodeEditSourceEditor
@testable import CodeEditTextView
@testable import QueryCraftFeature

@MainActor
@Suite(.serialized)
struct EditorCustomizationTests {
    private func preferences() throws -> (ApplicationPreferences, UserDefaults, String) {
        let name = "EditorCustomization.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (ApplicationPreferences(userDefaults: defaults), defaults, name)
    }

    @Test func colorHistoryGroupsPickerChangesAndRestoresBothAppearances() throws {
        let (preferences, defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let original = preferences.editorColors
        let session = EditorColorEditingSession(settings: original)
        for hex in ["#123456", "#234567", "#345678"] {
            session.change(preferences, key: "light.keyword") { $0.light.setHex(hex, for: .keyword) }
        }
        session.undo(preferences)
        #expect(preferences.editorColors == original)
        session.redo(preferences)
        #expect(preferences.editorColors.light.hex(for: .keyword, mode: .light) == "#345678")
        session.change(preferences) { $0.dark.apply(.ocean) }
        session.change(preferences) { $0.light.apply(.soft) }
        session.undo(preferences)
        #expect(preferences.editorColors.light.hex(for: .keyword, mode: .light) == "#345678")
        #expect(preferences.editorColors.dark.preset == .ocean)
        session.restore(preferences)
        #expect(preferences.editorColors == original)
        session.undo(preferences)
        #expect(preferences.editorColors.dark.preset == .ocean)
        session.change(preferences) { $0.light.italicComments = false }
        #expect(!session.canRedo)
        #expect(ApplicationPreferences(userDefaults: defaults).editorColors == preferences.editorColors)
    }

    @Test func themeFilesRoundTripAllRolesStylesAndPersistLibrary() throws {
        let (preferences, defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.editorColors.light.apply(.soft)
        preferences.editorColors.dark.apply(.ocean)
        preferences.editorColors.dark.boldKeywords = false
        preferences.editorColors.light.italicComments = false
        preferences.editorColors.light.setHex("#123456", for: .searchMatch)
        let data = try EditorThemeArchive(name: "我的主题 😀", settings: preferences.editorColors).data()
        let imported = try EditorThemeArchive.read(data)
        for mode in EditorColorMode.allCases {
            for role in EditorColorRole.allCases {
                #expect(imported.settings[mode].hex(for: role, mode: mode) == preferences.editorColors[mode].hex(for: role, mode: mode))
            }
        }
        #expect(!imported.settings.dark.boldKeywords)
        #expect(!imported.settings.light.italicComments)
        preferences.editorThemes = [imported]
        preferences.resetEditor()
        #expect(ApplicationPreferences(userDefaults: defaults).editorThemes == [imported])
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 99
        #expect(throws: (any Error).self) { try EditorThemeArchive.read(JSONSerialization.data(withJSONObject: json)) }
        #expect(throws: (any Error).self) { try EditorThemeArchive.read(Data(repeating: 0, count: 256 * 1024 + 1)) }
        json["version"] = 1
        var light = try #require(json["light"] as? [String: Any])
        var colors = try #require(light["colors"] as? [String: String])
        colors["keyword"] = "#INVALID"
        light["colors"] = colors; json["light"] = light
        #expect(throws: (any Error).self) { try EditorThemeArchive.read(JSONSerialization.data(withJSONObject: json)) }
        colors.removeValue(forKey: "keyword")
        light["colors"] = colors; json["light"] = light
        #expect(throws: (any Error).self) { try EditorThemeArchive.read(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test(arguments: EditorColorPreset.allCases, EditorColorMode.allCases)
    func paletteReadabilityAndStylesMatchRenderedAttributes(_ preset: EditorColorPreset, _ mode: EditorColorMode) throws {
        var settings = EditorColorSettings()
        settings[mode].apply(preset)
        let results = EditorColorReadability.checks(settings: settings, mode: mode)
        #expect(results.allSatisfy { $0.ratio.isFinite && $0.ratio >= 1 && $0.ratio <= 21 })
        for result in results {
            #expect(result.ratio >= result.minimum,
                    "\(preset.rawValue) \(mode.rawValue): \(result.role.rawValue) on \(result.background.rawValue) = \(result.ratio), target \(result.minimum)")
        }
        let theme = WorkspaceEditorTheme.make(for: mode.appearanceName, settings: settings)
        let controller = makeEditor("SELECT id FROM users -- comment", provider: WorkspaceSQLLanguageService())
        controller.configuration.appearance.theme = theme
        #expect(EditorHexColor.hex(controller.gutterView.textColor) == settings[mode].hex(for: .lineNumber, mode: mode))
        #expect(EditorHexColor.hex(controller.gutterView.selectedLineTextColor!) == settings[mode].hex(for: .currentLineNumber, mode: mode))
        let keywordFont = try #require(controller.attributesFor(.keyword)[.font] as? NSFont)
        #expect(NSFontManager.shared.traits(of: keywordFont).contains(.boldFontMask))
        settings[mode].boldKeywords = false
        settings[mode].italicComments = false
        controller.configuration.appearance.theme = WorkspaceEditorTheme.make(for: mode.appearanceName, settings: settings)
        let regularKeyword = try #require(controller.attributesFor(.keyword)[.font] as? NSFont)
        let regularComment = try #require(controller.attributesFor(.comment)[.font] as? NSFont)
        #expect(!NSFontManager.shared.traits(of: regularKeyword).contains(.boldFontMask))
        #expect(!NSFontManager.shared.traits(of: regularComment).contains(.italicFontMask))
        settings[mode].setHex(settings[mode].hex(for: .background, mode: mode), for: .keyword)
        #expect(EditorColorReadability.checks(settings: settings, mode: mode).contains { $0.role == .keyword && $0.ratio < 1.01 })
        #expect(abs(EditorColorReadability.ratio(.black, .white) - 21) < 0.01)
    }

    @Test(arguments: [false, true])
    func realTextUndoRedoAndCompositionSurvivePaletteChanges(_ json: Bool) throws {
        let original = json ? "{\"name\":\"hello\"}" : "SELECT name FROM users;"
        let controller = makeEditor(original, provider: json ? TreeSitterClient() : WorkspaceSQLLanguageService(), json: json)
        let textView = controller.textView!
        let undo = try #require(textView.undoManager)
        undo.beginUndoGrouping()
        textView.replaceCharacters(in: (original as NSString).range(of: "name"), with: "title")
        undo.endUndoGrouping()
        let edited = textView.string
        #expect(undo.canUndo)
        let selection = textView.selectedRange()
        controller.configuration.appearance.theme = WorkspaceEditorTheme.make(for: .darkAqua)
        #expect(textView.selectedRange() == selection)
        undo.undo(); #expect(textView.string == original)
        undo.redo(); #expect(textView.string == edited)
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = textView.markedRange()
        let markedSelection = textView.selectedRange()
        textView.textStorage.addAttribute(.underlineStyle, value: 1, range: marked)
        controller.configuration.appearance.theme = WorkspaceEditorTheme.make(for: .aqua)
        #expect(textView.hasMarkedText())
        #expect(textView.markedRange() == marked)
        #expect(textView.textStorage.attribute(.underlineStyle, at: marked.location, effectiveRange: nil) as? Int == 1)
        #expect(textView.selectedRange() == markedSelection)
        textView.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!textView.hasMarkedText())
        #expect(textView.string == "中" + edited)
    }

    @Test func nativeColorWellDetachesStaleCallbacks() {
        var lightWrites = 0
        var darkWrites = 0
        let light = EditorColorWell.Coordinator()
        light.change = { _ in lightWrites += 1 }
        let oldWell = EditorColorWell.Well()
        oldWell.target = light
        oldWell.action = #selector(EditorColorWell.Coordinator.changed(_:))
        oldWell.color = .red
        oldWell.sendAction(oldWell.action, to: oldWell.target)
        #expect(lightWrites == 1)
        EditorColorWell.dismantleNSView(oldWell, coordinator: light)
        oldWell.sendAction(oldWell.action, to: oldWell.target)
        #expect(lightWrites == 1)
        let dark = EditorColorWell.Coordinator()
        dark.change = { _ in darkWrites += 1 }
        let newWell = EditorColorWell.Well()
        newWell.target = dark; newWell.action = #selector(EditorColorWell.Coordinator.changed(_:))
        newWell.sendAction(newWell.action, to: newWell.target)
        #expect(darkWrites == 1)
        #expect(lightWrites == 1)
    }

    @Test(arguments: EditorColorPreviewKind.allCases)
    func previewClickUsesActualCapture(_ kind: EditorColorPreviewKind) async throws {
        let provider = EditorPreviewHighlighter(kind: kind)
        let controller = makeEditor(kind.source, provider: provider, json: kind.language == .json)
        let captures = try await query(provider, controller: controller)
        #expect(!captures.isEmpty)
        for capture in captures {
            #expect(provider.role(at: capture.range.location) == EditorPreviewHighlighter.role(for: capture.capture))
        }
    }

    @Test func themePanelResultsUseRealFilesAndKeepFailuresAtomic() throws {
        let (preferences, defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("我的主题😀.json")
        var settings = EditorColorSettings()
        settings.light.setHex("#123456", for: .keyword)
        settings.dark.setHex("#FEDCBA", for: .comment)
        settings.dark.italicComments = false
        try EditorThemeFiles.write(response: .cancel, url: url, settings: settings)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(try EditorThemeFiles.read(response: .cancel, url: url) == nil)
        try EditorThemeFiles.write(response: .OK, url: url, settings: settings)
        let bytes = try Data(contentsOf: url)
        let theme = try #require(try EditorThemeFiles.read(response: .OK, url: url))
        #expect(theme.name == "我的主题😀")
        #expect(theme.settings.light.hex(for: .keyword, mode: .light) == "#123456")
        #expect(theme.settings.dark.italicComments == false)
        for _ in 0..<3 {
            EditorThemeFiles.append(try #require(try EditorThemeFiles.read(response: .OK, url: url)), to: preferences)
        }
        #expect(preferences.editorThemes.map(\.name) == ["我的主题😀", "我的主题😀 (2)", "我的主题😀 (3)"])
        #expect(Set(preferences.editorThemes.map(\.id)).count == 3)
        let library = preferences.editorThemes
        let before = preferences.editorColors
        for invalid in [Data("{ invalid json".utf8), Data(repeating: 32, count: 256 * 1024 + 1)] {
            try invalid.write(to: url)
            #expect(throws: (any Error).self) { try EditorThemeFiles.read(response: .OK, url: url) }
            #expect(preferences.editorThemes == library)
            #expect(preferences.editorColors == before)
        }
        try bytes.write(to: url)
        try EditorThemeFiles.write(response: .cancel, url: url, settings: .init())
        #expect(try Data(contentsOf: url) == bytes)
        let absent = directory.appendingPathComponent("missing/theme.json")
        #expect(throws: (any Error).self) { try EditorThemeFiles.write(response: .OK, url: absent, settings: settings) }
        #expect(throws: (any Error).self) { try EditorThemeFiles.read(response: .OK, url: absent) }
        let reloaded = ApplicationPreferences(userDefaults: defaults)
        #expect(reloaded.editorThemes == library)
        reloaded.editorThemes.removeAll { $0.id == library[1].id }
        #expect(ApplicationPreferences(userDefaults: defaults).editorThemes.map(\.name) == ["我的主题😀", "我的主题😀 (3)"])
    }

    @Test func nativePanelSwitchesWellsAndReopeningStartsNewUndoStep() throws {
        let (preferences, defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let original = preferences.editorColors
        let session = EditorColorEditingSession(settings: original)
        let panel = NSColorPanel.shared
        defer { panel.orderOut(nil) }
        func well(_ mode: EditorColorMode, _ role: EditorColorRole) -> (EditorColorWell.Well, EditorColorWell.Coordinator) {
            let well = EditorColorWell.Well()
            let coordinator = EditorColorWell.Coordinator()
            coordinator.change = { color in
                session.change(preferences, key: mode.rawValue + role.rawValue) {
                    $0[mode].setHex(EditorHexColor.hex(color)!, for: role)
                }
            }
            well.beginChange = { session.finishContinuousChange() }
            well.target = coordinator
            well.action = #selector(EditorColorWell.Coordinator.changed(_:))
            return (well, coordinator)
        }
        let (light, lightCoordinator) = well(.light, .keyword)
        let (dark, darkCoordinator) = well(.dark, .comment)
        defer {
            EditorColorWell.dismantleNSView(light, coordinator: lightCoordinator)
            EditorColorWell.dismantleNSView(dark, coordinator: darkCoordinator)
        }
        light.activate(true)
        panel.orderOut(nil)
        #expect(light.isActive)
        for hex in ["#123456", "#234567", "#345678"] {
            panel.color = EditorHexColor.color(hex)
            light.takeColorFrom(panel)
        }
        #expect(preferences.editorColors.light.hex(for: .keyword, mode: .light) == "#345678")
        session.undo(preferences)
        #expect(preferences.editorColors == original)
        session.redo(preferences)
        light.deactivate()
        light.activate(true)
        panel.orderOut(nil)
        panel.color = EditorHexColor.color("#456789")
        light.takeColorFrom(panel)
        session.undo(preferences)
        #expect(preferences.editorColors.light.hex(for: .keyword, mode: .light) == "#345678")
        dark.activate(true)
        panel.orderOut(nil)
        #expect(light.isActive == false)
        #expect(dark.isActive)
        panel.color = EditorHexColor.color("#ABCDEF")
        dark.takeColorFrom(panel)
        #expect(preferences.editorColors.dark.hex(for: .comment, mode: .dark) == "#ABCDEF")
        #expect(preferences.editorColors.light.hex(for: .keyword, mode: .light) == "#345678")
        EditorColorWell.dismantleNSView(dark, coordinator: darkCoordinator)
        #expect(dark.isActive == false)
        #expect(panel.isVisible == false)
    }

    @Test(arguments: EditorColorPreviewKind.allCases)
    func composingChineseSurvivesRepeatedThemesAndHighlightCompletion(_ kind: EditorColorPreviewKind) async throws {
        let provider = EditorPreviewHighlighter(kind: kind)
        let controller = makeEditor(kind.source, provider: provider, json: kind.language == .json)
        let view = controller.textView!
        let undo = try #require(view.undoManager)
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        undo.beginUndoGrouping()
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        for mode in [EditorColorMode.dark, .light, .dark] {
            let range = view.markedRange()
            let selection = view.selectedRange()
            controller.configuration.appearance.theme = WorkspaceEditorTheme.make(for: mode.appearanceName)
            _ = try await query(provider, controller: controller)
            #expect(view.hasMarkedText())
            #expect(view.markedRange() == range)
            #expect(view.selectedRange() == selection)
        }
        view.setMarkedText("中文😀", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("中文😀", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        #expect(view.hasMarkedText() == false)
        #expect(view.string == "中文😀" + kind.source)
        undo.undo()
        #expect(view.string == kind.source)
        undo.redo()
        #expect(view.string == "中文😀" + kind.source)
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris], EditorColorMode.allCases)
    func executedSQLUsesTheSameColorsAndTypography(_ database: DatabaseType, _ mode: EditorColorMode) async throws {
        let sql = "SELECT 42; -- 中文😀"
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: sql))
        let captures = try await parser.highlights(in: .init(location: 0, length: sql.utf16.count), revision: .init(1), context: .init(databaseType: database))
        for enabled in [true, false] {
            var settings = EditorColorSettings()
            settings[mode].boldKeywords = enabled
            settings[mode].italicComments = enabled
            settings[mode].setHex("#123456", for: .keyword)
            let theme = WorkspaceEditorTheme.make(for: mode.appearanceName, settings: settings)
            let rendered = WorkspaceExecutedSQLWindowView.highlightedSQL(sql, highlights: captures, theme: theme, fontSize: 18)
            #expect(String(rendered.characters) == sql)
            let base = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
            for capture in captures {
                let range = try #require(Range(capture.range.nsRange, in: sql))
                let lo = try #require(AttributedString.Index(range.lowerBound, within: rendered))
                let hi = try #require(AttributedString.Index(range.upperBound, within: rendered))
                let name = WorkspaceSQLLanguageService.captureName(for: capture.kind)
                #expect(rendered[lo..<hi].foregroundColor == Color(nsColor: theme.colorFor(name)))
                #expect(rendered[lo..<hi].font == Font(theme.fontFor(for: name, from: base)))
            }
        }
    }

    @Test(arguments: EditorColorPreset.allCases, EditorColorMode.allCases)
    func renderPaletteMatrixWithSelectionAndSearch(_ preset: EditorColorPreset, _ mode: EditorColorMode) async throws {
        var settings = EditorColorSettings()
        settings[mode].apply(preset)
        let provider = WorkspaceSQLLanguageService()
        let source = EditorColorPreviewKind.mysql.source
        let controller = makeEditor(source, provider: provider)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: mode.appearanceName)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        controller.configuration.appearance.theme = WorkspaceEditorTheme.make(for: mode.appearanceName, settings: settings)
        controller.view.layoutSubtreeIfNeeded()
        let captures = try await query(provider, controller: controller)
        for capture in captures {
            controller.textView.textStorage.addAttributes(controller.attributesFor(capture.capture), range: capture.range)
        }
        let selected = (source as NSString).range(of: "SELECT u.id")
        controller.textView.selectionManager.setSelectedRange(selected)
        let manager = try #require(controller.textView.emphasisManager)
        controller.textView.layoutManager.layoutLines()
        manager.addEmphasis(.init(range: (source as NSString).range(of: "users")), for: "test-search")
        manager.addEmphasis(.init(range: (source as NSString).range(of: "users", options: .backwards), inactive: true), for: "test-search")
        let searchLayers = controller.textView.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        func containsColor(_ color: String) -> Bool {
            searchLayers.contains { layer in
                layer.fillColor.flatMap { NSColor(cgColor: $0) }.flatMap(EditorHexColor.hex) == color
            }
        }
        #expect(containsColor(settings[mode].hex(for: .searchCurrent, mode: mode)))
        #expect(containsColor(settings[mode].hex(for: .searchMatch, mode: mode)))
        let searchTextLayers = controller.textView.layer?.sublayers?.compactMap { $0 as? CATextLayer } ?? []
        #expect(searchTextLayers.count == 2)
        func textLayerContainsColor(_ hex: String) -> Bool {
            searchTextLayers.contains { layer in
                let text = layer.string as? NSAttributedString
                let color = text?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                return color.flatMap(EditorHexColor.hex) == hex
            }
        }
        #expect(textLayerContainsColor(settings[mode].hex(for: .searchText, mode: mode)))
        var custom = settings
        custom[mode].setHex("#123456", for: .selection)
        custom[mode].setHex("#CC44AA", for: .searchCurrent)
        custom[mode].setHex("#00AA66", for: .searchMatch)
        custom[mode].setHex("#112233", for: .searchText)
        controller.configuration.appearance.theme = WorkspaceEditorTheme.make(for: mode.appearanceName, settings: custom)
        #expect(containsColor("#CC44AA"))
        #expect(containsColor("#00AA66"))
        #expect(textLayerContainsColor("#112233"))
        manager.removeAllEmphases()
        #expect(EditorHexColor.hex(controller.textView.selectionManager.selectionBackgroundColor) == "#123456")
        controller.configuration.appearance.theme = WorkspaceEditorTheme.make(for: mode.appearanceName, settings: settings)
        controller.textView.layoutManager.layoutLines()
        manager.addEmphasis(.init(range: (source as NSString).range(of: "users")), for: "test-search")
        manager.addEmphasis(.init(range: (source as NSString).range(of: "users", options: .backwards), inactive: true), for: "test-search")
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.layoutManager.layoutLines()
        manager.updateLayerBackgrounds()
        if let directory = ProcessInfo.processInfo.environment["QUERYCRAFT_COLOR_SNAPSHOTS"] {
            let view = controller.view
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let context = try #require(CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: 2, y: 2)
            func displayLayers(_ layer: CALayer) {
                layer.displayIfNeeded()
                layer.sublayers?.forEach(displayLayers)
            }
            if let layer = view.layer { displayLayers(layer) }
            window.appearance?.performAsCurrentDrawingAppearance { view.layer?.render(in: context) }
            let layeredBitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            let data = try #require(layeredBitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("palette-\(preset.rawValue)-\(mode.rawValue).png"))
        }
    }

    @Test(arguments: EditorColorMode.allCases)
    func searchForegroundAppearsInRenderedPixels(_ mode: EditorColorMode) async throws {
        let controller = makeEditor("users", provider: WorkspaceSQLLanguageService())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: mode.appearanceName)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        controller.view.layoutSubtreeIfNeeded()
        let view = controller.textView!
        view.textStorage.addAttribute(.foregroundColor, value: NSColor.green, range: view.documentRange)
        view.layoutManager.layoutLines()
        let manager = try #require(view.emphasisManager)
        manager.setColors(active: .yellow, inactive: .yellow, activeText: .magenta, inactiveText: .magenta, selection: .blue)
        manager.addEmphasis(.init(range: view.documentRange), for: "pixels")
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutSubtreeIfNeeded()
        view.textStorage.addAttribute(.foregroundColor, value: NSColor.green, range: view.documentRange)
        view.layoutManager.invalidateLayoutForRect(view.visibleRect)
        view.layoutManager.layoutLines()
        manager.updateLayerBackgrounds()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let context = try #require(CGContext(data: nil, width: 800, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        controller.view.layer?.render(in: context)
        let rendered = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        var magentaPixels = 0
        var originalGlyphPixels = 0
        for y in 0..<rendered.pixelsHigh {
            for x in 0..<rendered.pixelsWide {
                if let c = rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   c.redComponent > 0.8, c.greenComponent < 0.2, c.blueComponent > 0.8 { magentaPixels += 1 }
                if x < 600, let c = rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   c.redComponent < 0.2, c.greenComponent > 0.8, c.blueComponent < 0.2 { originalGlyphPixels += 1 }
            }
        }
        #expect(magentaPixels > 20)
        #expect(originalGlyphPixels < 5, "Search text must replace rather than double-draw the original glyphs")
        if let directory = ProcessInfo.processInfo.environment["QUERYCRAFT_COLOR_SNAPSHOTS"] {
            try #require(rendered.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("search-pixels-\(mode.rawValue).png"))
        }
    }

    private func makeEditor(_ source: String, provider: any HighlightProviding, json: Bool = false) -> TextViewController {
        let controller = TextViewController(string: source, language: json ? .json : .sql,
            configuration: .init(appearance: .init(theme: WorkspaceEditorTheme.make(for: .aqua),
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false)),
            cursorPositions: [], highlightProviders: [provider])
        controller.loadViewIfNeeded()
        return controller
    }
    private func query(_ provider: any HighlightProviding, controller: TextViewController) async throws -> [HighlightRange] {
        try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: controller.textView, range: NSRange(location: 0, length: controller.text.utf16.count)) {
                continuation.resume(with: $0)
            }
        }
    }
}
