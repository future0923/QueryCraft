import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceNativeFocusObserverTests {
    @Test
    func scopeUsesTheFieldEditorsActualControl() async throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let inside = NSTextField(frame: .init(x: 10, y: 110, width: 180, height: 24))
        let outside = NSTextField(frame: .init(x: 10, y: 20, width: 180, height: 24))
        var focused = false
        let observer = WorkspaceNativeFocusObserver.FocusView(matches: { _ in true },
            requiresContainedResponder: true, didChange: { focused = $0 })
        observer.frame = .init(x: 0, y: 100, width: 400, height: 100)
        window.contentView?.addSubview(inside)
        window.contentView?.addSubview(outside)
        window.contentView?.addSubview(observer)
        defer { window.makeFirstResponder(nil); window.close() }
        inside.selectText(nil)
        // This hidden unit-test window has no application event loop. Deliver
        // the notification that AppKit emits after updating a visible window.
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        try await Task.sleep(for: .milliseconds(30))
        #expect(focused)
        outside.selectText(nil)
        #expect((window.firstResponder as? NSTextView)?.delegate === outside)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        try await Task.sleep(for: .milliseconds(30))
        #expect(focused == false)
        inside.selectText(nil)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        try await Task.sleep(for: .milliseconds(30))
        #expect(focused)
    }

    @Test
    func tracksNativeEditorFocusAndIgnoresStaleTransitions() async throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        let other = NSTextField(frame: .init(x: 0, y: 110, width: 200, height: 24))
        var reported: [Bool] = []
        let observer = WorkspaceNativeFocusObserver.FocusView(
            matches: { $0 === editor }, didChange: { reported.append($0) })
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(other)
        window.contentView?.addSubview(observer)
        defer { window.makeFirstResponder(nil); window.close() }
        window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reported.last == true)
        other.selectText(nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reported.last == false)
        for _ in 0..<10 {
            window.makeFirstResponder(editor)
            other.selectText(nil)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(reported.last == false)
        window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reported.last == true)
        observer.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(reported.last == false)
        let count = reported.count
        other.selectText(nil)
        window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reported.count == count)
    }

    @Test
    func detachedEditorCannotKeepCommandsInItsOldWindow() async throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        var focused = false
        let observer = WorkspaceNativeFocusObserver.FocusView(
            matches: { $0 === editor }, didChange: { focused = $0 })
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(observer)
        defer { window.makeFirstResponder(nil); window.close() }
        window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(30))
        #expect(focused)
        observer.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(30))
        #expect(focused == false)
        window.makeFirstResponder(nil)
        window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(30))
        #expect(focused == false)
    }
}
