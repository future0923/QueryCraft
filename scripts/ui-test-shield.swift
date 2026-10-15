import AppKit
import ApplicationServices

let taskRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
final class Shield: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var tap: CFMachPort?
    var timer: Timer?
    var remaining = 300
    let buttonRects: [NSRect] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                controller.stop(reason: "Input isolation stopped")
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                controller.stop(reason: "User pressed Escape")
                return nil
            }
            // Only explicitly registered automation processes may inject global events.
            // Native XCTest events stay inside the test process and need no exception.
            if let allowed = try? String(contentsOf: taskRoot.appendingPathComponent("allowed-pids"), encoding: .utf8),
               allowed.split(separator: "\n").contains(Substring(String(event.getIntegerValueField(.eventSourceUnixProcessID)))) {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }, userInfo: nil)
        guard let tap else { stop(reason: "Cannot enable input isolation"); return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { stop(reason: "Input tap unavailable"); return }
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
            panel.isOpaque = true
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = false
            let text = NSTextField(wrappingLabelWithString: "QueryCraft 界面测试隔离中\n\n按 Esc 随时退出并停止测试\n最多 5 分钟自动解除\n\n测试结束后自动恢复桌面")
            text.textColor = .white
            text.font = .systemFont(ofSize: 23)
            text.alignment = .center
            text.frame = NSRect(x: max(0, (screen.frame.width - 620)/2), y: max(0, (screen.frame.height - 180)/2), width: 620, height: 180)
            panel.contentView?.addSubview(text)
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        guard !windows.isEmpty else { stop(reason: "No displays to cover"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            guard self.windows.allSatisfy({ window in visible.contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber } }) else {
                self.stop(reason: "Not all displays were covered"); return
            }
            try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: taskRoot.appendingPathComponent("shield.ready"), atomically: true, encoding: .utf8)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            if fm.fileExists(atPath: taskRoot.appendingPathComponent("stop").path) { controller.stop(reason: "Completed") }
            if let tap = controller.tap, !CGEvent.tapIsEnabled(tap: tap) { controller.stop(reason: "Input isolation was disabled") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { controller.stop(reason: "Five minute limit reached") }
    }
    func stop(reason: String) {
        try? reason.write(to: taskRoot.appendingPathComponent("stopped"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: taskRoot.appendingPathComponent("shield.ready"))
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        timer?.invalidate()
        windows.forEach { $0.orderOut(nil) }
        NSApplication.shared.terminate(nil)
    }
}
let controller = Shield()
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = controller
NSApplication.shared.run()
