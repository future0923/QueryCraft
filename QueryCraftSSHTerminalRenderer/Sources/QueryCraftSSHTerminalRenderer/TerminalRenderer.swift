import AppKit
import CQueryCraftSSHTerminalRendererAPI
@preconcurrency import SwiftTerm

@MainActor private final class TerminalRenderer: NSObject, @preconcurrency TerminalViewDelegate {
    let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    let callbacks: qc_terminal_callbacks
    let context: UnsafeMutableRawPointer?
    private var darkAppearance: Bool?
    init(callbacks: qc_terminal_callbacks, context: UnsafeMutableRawPointer?) {
        self.callbacks = callbacks; self.context = context
        super.init()
        view.terminalDelegate = self
        view.getTerminal().changeHistorySize(5000)
        view.optionAsMetaKey = true
        view.disableFullRedrawOnAnyChanges = true
    }
    func appearance(dark: Bool) {
        guard darkAppearance != dark else { return }
        darkAppearance = dark
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.nativeBackgroundColor = dark ? NSColor.black : NSColor.textBackgroundColor
        view.nativeForegroundColor = dark ? NSColor(calibratedWhite: 0.88, alpha: 1) : NSColor.textColor
        view.caretColor = .controlAccentColor
        view.getTerminal().refresh(startRow: 0, endRow: view.getTerminal().rows - 1)
        view.needsDisplay = true
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        data.withUnsafeBufferPointer { buffer in callbacks.input?(context, buffer.baseAddress, buffer.count) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        callbacks.resize?(context, UInt32(clamping: newCols), UInt32(clamping: newRows))
    }
    func setTerminalTitle(source: TerminalView, title: String) {
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(128)
        Array(clean.utf8).withUnsafeBufferPointer { callbacks.title?(context, $0.baseAddress, $0.count) }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    // Remote control sequences never touch the clipboard, open links or run local programs.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
}

@_cdecl("querycraft_ssh_terminal_renderer_version")
public func rendererVersion() -> UInt32 { UInt32(QC_SSH_TERMINAL_RENDERER_ABI_VERSION) }

// These exported synchronous C entry points have an explicit main-thread ABI.
// Global actor isolation protects all AppKit/SwiftTerm state inside the module.
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_create")
public func rendererCreate(_ callbacks: UnsafePointer<qc_terminal_callbacks>?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let callbacks, callbacks.pointee.size == MemoryLayout<qc_terminal_callbacks>.size,
          callbacks.pointee.input != nil, callbacks.pointee.resize != nil, callbacks.pointee.title != nil else { return nil }
    return Unmanaged.passRetained(TerminalRenderer(callbacks: callbacks.pointee, context: context)).toOpaque()
}
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_view")
public func rendererView(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let handle else { return nil }
    return Unmanaged.passUnretained(Unmanaged<TerminalRenderer>.fromOpaque(handle).takeUnretainedValue().view).toOpaque()
}
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_feed")
public func rendererFeed(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) {
    guard Thread.isMainThread, let handle, let bytes, count > 0, count <= QC_SSH_TERMINAL_RENDERER_MAX_FEED else { return }
    Unmanaged<TerminalRenderer>.fromOpaque(handle).takeUnretainedValue().view.applyOutput(ArraySlice(UnsafeBufferPointer(start: bytes, count: count)))
}
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_appearance")
public func rendererAppearance(_ handle: UnsafeMutableRawPointer?, _ dark: UInt32) {
    guard Thread.isMainThread, let handle else { return }
    Unmanaged<TerminalRenderer>.fromOpaque(handle).takeUnretainedValue().appearance(dark: dark != 0)
}
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_columns")
public func rendererColumns(_ handle: UnsafeMutableRawPointer?) -> UInt32 {
    guard Thread.isMainThread, let handle else { return 0 }
    return UInt32(clamping: Unmanaged<TerminalRenderer>.fromOpaque(handle).takeUnretainedValue().view.getTerminal().cols)
}
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_rows")
public func rendererRows(_ handle: UnsafeMutableRawPointer?) -> UInt32 {
    guard Thread.isMainThread, let handle else { return 0 }
    return UInt32(clamping: Unmanaged<TerminalRenderer>.fromOpaque(handle).takeUnretainedValue().view.getTerminal().rows)
}
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_visible_text")
public func rendererText(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    guard Thread.isMainThread, let handle, let bytes, capacity > 0, capacity <= QC_SSH_TERMINAL_RENDERER_MAX_TEXT else { return 0 }
    let terminal = Unmanaged<TerminalRenderer>.fromOpaque(handle).takeUnretainedValue().view.getTerminal()
    let text = (0..<terminal.rows).compactMap { row in
        terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { terminal.getCharacter(for: $0) })
    }.joined(separator: "\n")
    let data = Array(text.utf8.prefix(capacity)); bytes.update(from: data, count: data.count); return data.count
}
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_destroy")
public func rendererDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard Thread.isMainThread, let handle else { return }
    let renderer = Unmanaged<TerminalRenderer>.fromOpaque(handle).takeRetainedValue()
    renderer.view.terminalDelegate = nil
}

// Optional capability query; base renderer ABI remains 1. No Swift UI types
// escape the plugin. Flags describe the remote program's current input modes.
@MainActor @_cdecl("querycraft_ssh_terminal_renderer_input_flags")
public func rendererInputFlags(_ handle: UnsafeMutableRawPointer?) -> UInt32 {
    guard Thread.isMainThread, let handle else { return 0 }
    let terminal = Unmanaged<TerminalRenderer>.fromOpaque(handle).takeUnretainedValue().view.getTerminal()
    return (terminal.bracketedPasteMode ? 1 : 0) | (terminal.isCurrentBufferAlternate ? 2 : 0)
}
