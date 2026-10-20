import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor
struct DataTransferPresentationTests {
    @Test("The native workbench preserves its frame during load, failure, empty results and history")
    func layout() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "QueryCraftTransferPreview")
        let environment = ProcessInfo.processInfo.environment
        let isolation = (environment["QUERYCRAFT_UI_VISUAL_QA_DIR"] ?? environment["TEST_RUNNER_QUERYCRAFT_UI_VISUAL_QA_DIR"]).map { URL(fileURLWithPath: $0) }
        if let isolation { try #require(FileManager.default.fileExists(atPath: isolation.appending(path: "shield.ready").path)) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = profile(name: "MySQL 5.7 开发环境", database: "source")
        let target = profile(name: "MySQL 8.0 测试环境", database: "target")
        let libraryURL = root.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let store = DataTransferLibraryStore(url: libraryURL)
        let factory = TransferTestFactory(failInsert: nil, failCommit: false)
        let model = DataTransferWorkbenchModel(library: store, manager: DataTransferManager(historyURL: root.appending(path: UUID().uuidString + ".json")),
                                               repository: InMemoryConnectionProfileRepository(profiles: [source, target]), credentials: InMemoryCredentialStore(), catalog: .init(factory: factory))
        await model.loadProfiles()
        model.chooseProfile(source.id, side: .source); model.chooseProfile(target.id, side: .target)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !model.loadingSides.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.errorMessage.isEmpty)
        let object = try #require(model.objects.first)
        model.select(object, enabled: true)
        model.configuration.tableFilters[object.name] = "id <= 90000"
        model.save()
        #expect(!model.isDirty)
        for dark in [false, true] {
            let host = NSHostingView(rootView: DataTransferWorkbenchView(model: model).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1120, height: 790), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if isolation != nil { window.animationBehavior = .none; window.center(); window.orderFrontRegardless() }
            defer { window.close() }
            for size in [NSSize(width: 1120, height: 790), NSSize(width: 920, height: 680)] {
                window.setContentSize(size)
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
                }
                #expect(host.bounds.size == size)
                try checkConfigurationControls(in: host)
                model.errorMessage = "模拟失败；保留当前选项和列表。Simulated failure; existing options and layout remain."
                host.layoutSubtreeIfNeeded(); #expect(host.bounds.size == size)
                model.errorMessage = ""
                await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
                host.layoutSubtreeIfNeeded()
                if let isolation {
                    try #require(FileManager.default.fileExists(atPath: isolation.appending(path: "shield.ready").path))
                    try await Task.sleep(for: .milliseconds(300))
                    let name = "visible-transfer-\(dark ? "dark" : "light")-\(Int(size.width)).png"
                    let request = isolation.appending(path: "capture-request"), done = isolation.appending(path: "capture-done")
                    try? FileManager.default.removeItem(at: done)
                    try "\(window.windowNumber)\n\(root.appending(path: name).path)".write(to: request, atomically: true, encoding: .utf8)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                    while !FileManager.default.fileExists(atPath: done.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
                    #expect((try? String(contentsOf: done, encoding: .utf8)) == "0")
                }
                try snapshot(host, appearance: window.effectiveAppearance, at: root.appending(path: "transfer-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
                model.showingHistory = true; host.layoutSubtreeIfNeeded(); #expect(host.bounds.size == size)
                model.showingHistory = false
            }
        }
        model.close()
    }

    @Test("Initial workbench fits the smallest window and renders both appearances")
    func initialLayout() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "QueryCraftTransferPreview")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let model = DataTransferWorkbenchModel(library: .init(url: state.appending(path: "tasks.json")), manager: .init(historyURL: state.appending(path: "history.json")), repository: InMemoryConnectionProfileRepository(), credentials: InMemoryCredentialStore())
        defer { model.close() }
        for dark in [false, true] {
            let host = NSHostingView(rootView: DataTransferWorkbenchView(model: model).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 920, height: 638), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            for size in [NSSize(width: 920, height: 638), NSSize(width: 1060, height: 740)] {
                window.setContentSize(size)
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
                }
                #expect(host.bounds.size == size)
                #expect(host.fittingSize.width <= size.width)
                #expect(host.fittingSize.height <= size.height)
                try checkConfigurationControls(in: host)
                try snapshot(host, appearance: window.effectiveAppearance, at: root.appending(path: "initial-transfer-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
                let content = try #require(nativeConfigurationControls(in: host).first { $0.identifier?.rawValue == "transfer.content" })
                let action = try #require(content.action)
                content.selectItem(at: 2)
                #expect(NSApp.sendAction(action, to: content.target, from: content))
                #expect(model.configuration.content == .dataOnly)
                content.selectItem(at: 0)
                #expect(NSApp.sendAction(action, to: content.target, from: content))
                #expect(model.configuration.content == .structureAndData)
            }
        }
    }

    private func snapshot(_ host: NSView, appearance: NSAppearance, at url: URL) throws {
        let context = try #require(CGContext(data: nil, width: Int(host.bounds.width * 2), height: Int(host.bounds.height * 2), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: 0, y: host.bounds.height)
        context.scaleBy(x: 1, y: -1)
        appearance.performAsCurrentDrawingAppearance { host.layer?.render(in: context) }
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        Attachment.record(data, named: url.lastPathComponent)
    }

    private func checkConfigurationControls(in host: NSView) throws {
        let controls = nativeConfigurationControls(in: host)
        #expect(controls.count == 3)
        let reference = try #require(controls.first)
        let frame = host.convert(reference.bounds, from: reference)
        #expect(frame.width >= 180)
        for control in controls {
            let actual = host.convert(control.bounds, from: control)
            #expect(abs(actual.width - frame.width) < 1)
            #expect(abs(actual.minX - frame.minX) < 1)
            #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(actual))
        }
        let tasks = try #require(descendants(host).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "transfer.savedTasks" })
        #expect(tasks.focusRingType == .none)
    }

    private func nativeConfigurationControls(in host: NSView) -> [NSPopUpButton] {
        return descendants(host).compactMap { $0 as? NSPopUpButton }.filter { $0.identifier?.rawValue.hasPrefix("transfer.") == true }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test("Transfer and grid pickers share the native search and selection surface")
    func searchPickerSurface() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "QueryCraftTransferPreview")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dark in [false, true] {
            let content = WorkspaceSearchPickerContent(
                query: .constant(""), highlightedOption: .constant("source"), focusRequest: 0,
                placeholder: "搜索连接", accessibilityIdentifier: "transfer.pickerPreview", submit: {}, cancel: {}, moveUp: {}, moveDown: {}
            ) {
                ForEach(["source", "target"], id: \.self) { id in
                    HStack {
                        Image(systemName: "checkmark").opacity(id == "source" ? 1 : 0)
                        Text(id == "source" ? "本地演练 · 源（MySQL 5.7）" : "本地演练 · 目标（MySQL 8.0）")
                        Spacer()
                    }.tag(id).listRowSeparator(.hidden)
                }
            }.environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 320), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
            }
            let search = try #require(descendants(host).compactMap { $0 as? NSSearchField }.first)
            #expect(search.placeholderString == "搜索连接")
            #expect(search.sendsSearchStringImmediately)
            try snapshot(host, appearance: window.effectiveAppearance, at: root.appending(path: "search-picker-\(dark ? "dark" : "light").png"))
        }
    }

    @Test("Dirty task switching requires discard and saved configs retain filters")
    func switching() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DataTransferLibraryStore(url: root.appending(path: "tasks.json"))
        let model = DataTransferWorkbenchModel(library: library, manager: DataTransferManager(historyURL: root.appending(path: "history.json")),
                                               repository: InMemoryConnectionProfileRepository(), credentials: InMemoryCredentialStore())
        model.configuration.source.profileID = UUID()
        model.configuration.tableFilters["a.b"] = "id<50"
        model.save()
        let task = try #require(library.library.tasks.first)
        model.configuration.batchSize = 2000
        model.requestTask(nil)
        #expect(model.showingDiscard)
        #expect(model.configuration.batchSize == 2000)
        model.discardAndSwitch()
        #expect(model.configuration == DataTransferConfiguration())
        model.requestTask(task)
        #expect(model.configuration.tableFilters["a.b"] == "id<50")
        model.close()
    }

    private func profile(name: String, database: String) -> ConnectionProfile {
        .init(id: UUID(), name: name, groupID: nil, host: "localhost", port: 3306, username: "test", authenticationMethod: .none, defaultDatabase: database, tlsMode: .disabled, storesCredential: false, createdAt: Date())
    }

    @Test("Slow obsolete source requests cannot replace a rapidly changed connection")
    func staleLoading() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = profile(name: "old", database: "source"), b = profile(name: "new", database: "target")
        let gate = TransferTestGate()
        let factory = TransferTestFactory(failInsert: nil, failCommit: false, gate: gate)
        let model = DataTransferWorkbenchModel(library: .init(url: root.appending(path: "tasks.json")), manager: .init(historyURL: root.appending(path: "history.json")),
                                               repository: InMemoryConnectionProfileRepository(profiles: [a, b]), credentials: InMemoryCredentialStore(), catalog: .init(factory: factory))
        await model.loadProfiles()
        model.chooseProfile(a.id, side: .source)
        await gate.waitUntilEntered()
        #expect(!model.sourceLoaded)
        #expect(model.objects.isEmpty)
        model.chooseProfile(b.id, side: .source)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !model.loadingSides.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.configuration.source.profileID == b.id)
        #expect(model.configuration.source.database == "target")
        await gate.release()
        for _ in 0..<5 { await Task.yield() }
        #expect(model.configuration.source.profileID == b.id)
        #expect(model.configuration.source.database == "target")
        #expect(model.errorMessage.isEmpty)
        model.close()
    }

    @Test("Metadata failure, retry and successful empty catalog remain distinct")
    func loadingStates() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(name: "test", database: "source")
        let factory = TransferTestFactory(failInsert: nil, failCommit: false)
        let model = DataTransferWorkbenchModel(library: .init(url: root.appending(path: "tasks.json")), manager: .init(historyURL: root.appending(path: "history.json")),
                                               repository: InMemoryConnectionProfileRepository(profiles: [profile]), credentials: InMemoryCredentialStore(), catalog: .init(factory: factory))
        await model.loadProfiles(); await factory.log.setLoadingFailure(true)
        model.chooseProfile(profile.id, side: .source)
        var deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !model.loadingSides.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!model.sourceLoaded); #expect(!model.errorMessage.isEmpty)
        await factory.log.setLoadingFailure(false); await factory.log.setEmptyCatalog(true)
        model.refresh()
        deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !model.loadingSides.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.sourceLoaded); #expect(model.objects.isEmpty); #expect(model.errorMessage.isEmpty)
        await factory.log.setEmptyCatalog(false)
        model.refresh()
        deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !model.loadingSides.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.sourceLoaded); #expect(!model.objects.isEmpty)
        model.close()
    }
}
