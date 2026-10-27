import AppKit
import CQueryCraftSSHPluginAPI
import Darwin

/// Host-facing renderer adapter. SwiftTerm exists only inside the installed SSH plugin.
/// C ABI calls/callbacks and the borrowed AppKit view are confined to the main actor.
@MainActor final class SSHTerminalSurface {
    weak var session: SSHTerminalSession?
    let view: NSView
    private let library: Library
    private let handle: UnsafeMutableRawPointer
    // A separate context can be created before self is initialized. The renderer
    // borrows it until destroy; its weak surface avoids a retain cycle.
    private let callbacks: Callbacks
    private var pendingSize: (columns: Int, rows: Int)?
    private var resizeTask: Task<Void, Never>?

    init(bundleURL: URL) throws {
        let library = try Library.load(bundleURL: bundleURL)
        let callbacks = Callbacks()
        var raw = qc_terminal_callbacks()
        raw.size = UInt32(MemoryLayout<qc_terminal_callbacks>.size)
        raw.input = { context, bytes, count in
            guard Thread.isMainThread, let context, let bytes, count > 0, count <= 1_048_576 else { return }
            MainActor.assumeIsolated { Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue().surface?.session?.send(Data(bytes: bytes, count: count)) }
        }
        raw.resize = { context, columns, rows in
            guard Thread.isMainThread, let context else { return }
            MainActor.assumeIsolated { Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue().surface?.scheduleResize(columns: Int(columns), rows: Int(rows)) }
        }
        raw.title = { context, bytes, count in
            guard Thread.isMainThread, let context, let bytes, count <= 1024 else { return }
            MainActor.assumeIsolated {
                let title = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
                Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue().surface?.session?.title = String(String.UnicodeScalarView(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(128).description
            }
        }
        guard let handle = library.create(&raw, Unmanaged.passUnretained(callbacks).toOpaque()) else { throw Self.unavailable() }
        guard let rawView = library.view(handle), let view = Unmanaged<AnyObject>.fromOpaque(rawView).takeUnretainedValue() as? NSView else {
            library.destroy(handle); throw Self.unavailable()
        }
        self.library = library; self.handle = handle; self.view = view; self.callbacks = callbacks
        callbacks.surface = self
        view.setAccessibilityLabel(AppCopy.current.text("SSH 交互式终端", "Interactive SSH terminal"))
    }
    deinit {
        MainActor.assumeIsolated { library.destroy(handle); callbacks.surface = nil }
    }
    // Renderer callbacks can arrive inside AppKit/SwiftUI layout. Publish dimensions
    // on the next main-actor turn, coalescing a resize burst without reentering layout.
    private func scheduleResize(columns: Int, rows: Int) {
        pendingSize = (columns, rows)
        guard resizeTask == nil else { return }
        resizeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.resizeTask = nil
            guard let size = self.pendingSize else { return }
            self.pendingSize = nil
            self.session?.resize(columns: size.columns, rows: size.rows)
        }
    }
    var inputFlags: UInt32? { library.inputFlags.map { $0(handle) } }
    var columns: Int { Int(library.columns(handle)) }
    var rows: Int { Int(library.rows(handle)) }
    func feed(_ data: ArraySlice<UInt8>) {
        guard !data.isEmpty, data.count <= QC_SSH_TERMINAL_RENDERER_MAX_FEED else { return }
        data.withUnsafeBufferPointer { library.feed(handle, $0.baseAddress, $0.count) }
    }
    func appearance(dark: Bool) { library.appearance(handle, dark ? 1 : 0) }
    var visibleText: String {
        var bytes = [UInt8](repeating: 0, count: Int(QC_SSH_TERMINAL_RENDERER_MAX_TEXT))
        let count = bytes.withUnsafeMutableBufferPointer { library.text(handle, $0.baseAddress, $0.count) }
        guard count > 0, count <= bytes.count else { return "" }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }
    static func unavailable() -> MCPFailure {
        MCPFailure(AppCopy.current.text("此 SSH 插件不含兼容的终端组件，请安装 SSH 0.9.0 或更新插件。MCP 命令功能仍可独立使用。", "Install SSH 0.9.0 or later with a compatible terminal renderer. MCP commands remain independently available."), code: .unsupported)
    }
    @MainActor private final class Callbacks { weak var surface: SSHTerminalSurface? }

    @MainActor private final class Library {
        private static var loaded: Library?
        private static var attemptedURL: URL?
        let url: URL
        let create: qc_terminal_renderer_create_fn
        let view: qc_terminal_renderer_view_fn
        let feed: qc_terminal_renderer_feed_fn
        let appearance: qc_terminal_renderer_appearance_fn
        let columns: qc_terminal_renderer_dimension_fn
        let rows: qc_terminal_renderer_dimension_fn
        let inputFlags: qc_terminal_renderer_dimension_fn?
        let text: qc_terminal_renderer_text_fn
        let destroy: qc_terminal_renderer_destroy_fn
        static func load(bundleURL: URL) throws -> Library {
            let root = bundleURL.resolvingSymlinksInPath()
            let url = root.appending(path: "Contents/PlugIns/TerminalRenderer.bundle").resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw SSHTerminalSurface.unavailable() }
            // Swift/Objective-C UI classes cannot safely be registered twice from
            // different binary versions. Existing tabs keep the immutable code.
            if let attemptedURL, attemptedURL != url {
                throw MCPFailure(AppCopy.current.text("SSH 终端组件已更新，请重启 QueryCraft 后使用新版。", "The SSH terminal component changed. Restart QueryCraft to use the new version."), code: .sessionBusy)
            }
            if let loaded { return loaded }
            try SSHPlugin.verifySignature(at: root)
            try SSHPlugin.verifySignature(at: url, identifier: "io.github.future0923.QueryCraft.SSH.TerminalRenderer")
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "io.github.future0923.QueryCraft.SSH.TerminalRenderer",
                  bundle.object(forInfoDictionaryKey: "QCSSHTerminalRendererABIVersion") as? Int == 1,
                  let executable = bundle.executableURL else { throw SSHTerminalSurface.unavailable() }
            guard let handle = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL) else { throw SSHTerminalSurface.unavailable() }
            attemptedURL = url
            // Keep modules resident even if symbol validation fails: dlopen may
            // already have registered Objective-C classes with the runtime.
            let library = try Library(url: url, handle: handle)
            loaded = library; return library
        }
        private init(url: URL, handle: UnsafeMutableRawPointer) throws {
            func symbol<T>(_ name: String, _: T.Type) throws -> T {
                guard let value = dlsym(handle, "querycraft_ssh_terminal_renderer_" + name) else { throw SSHTerminalSurface.unavailable() }
                return unsafeBitCast(value, to: T.self)
            }
            let version = try symbol("version", qc_terminal_renderer_version_fn.self)
            guard version() == QC_SSH_TERMINAL_RENDERER_ABI_VERSION else { throw SSHTerminalSurface.unavailable() }
            self.url = url
            create = try symbol("create", qc_terminal_renderer_create_fn.self)
            view = try symbol("view", qc_terminal_renderer_view_fn.self)
            feed = try symbol("feed", qc_terminal_renderer_feed_fn.self)
            appearance = try symbol("appearance", qc_terminal_renderer_appearance_fn.self)
            columns = try symbol("columns", qc_terminal_renderer_dimension_fn.self)
            rows = try symbol("rows", qc_terminal_renderer_dimension_fn.self)
            inputFlags = dlsym(handle, "querycraft_ssh_terminal_renderer_input_flags").map {
                unsafeBitCast($0, to: qc_terminal_renderer_dimension_fn.self)
            }
            text = try symbol("visible_text", qc_terminal_renderer_text_fn.self)
            destroy = try symbol("destroy", qc_terminal_renderer_destroy_fn.self)
        }
    }
}
