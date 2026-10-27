import AppKit
@preconcurrency import SwiftTerm

/// AppKit work is batched at the stream/frame boundary, rather than once per output line or wheel event.
@MainActor final class InteractiveTerminalView: TerminalView {
    private var applyingOutput = false
    private var outputScroll: Int?
    private var wheelRemainder = 0.0
    private var pendingWheelLines = 0
    private var wheelTarget: WheelTarget?
    private var wheelTimer: Timer?
    private var wheelPoint = NSPoint.zero
    private var wheelModifiers: NSEvent.ModifierFlags = []
    private var lastWheelTimestamp = 0.0

    private enum WheelTarget: Equatable {
        case history, cursor(application: Bool), mouse(alternate: Bool, mode: Int)
    }

    func applyOutput(_ bytes: ArraySlice<UInt8>) {
        let previousTarget = target(modifiers: wheelModifiers)
        applyingOutput = true
        feed(byteArray: bytes)
        applyingOutput = false
        if let row = outputScroll {
            outputScroll = nil
            super.scrolled(source: getTerminal(), yDisp: row)
        }
        if previousTarget != target(modifiers: wheelModifiers) { resetWheel() }
    }

    override func scrolled(source: Terminal, yDisp: Int) {
        if applyingOutput { outputScroll = yDisp }
        else { super.scrolled(source: source, yDisp: yDisp) }
    }

    override func bufferActivated(source: Terminal) {
        resetWheel()
        super.bufferActivated(source: source)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        enqueueWheel(delta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
            point: point, modifiers: event.modifierFlags, timestamp: event.timestamp,
            beginsGesture: event.phase == .began)
    }

    // An isolated view can exercise the same event path without posting input to the user's desktop.
    func enqueueWheel(delta: Double, precise: Bool, point: NSPoint, modifiers: NSEvent.ModifierFlags,
                      timestamp: Double, beginsGesture: Bool = false) {
        guard delta.isFinite, delta != 0 else { return }
        let nextTarget = target(modifiers: modifiers)
        guard let nextTarget else { resetWheel(); return }
        if beginsGesture || nextTarget != wheelTarget || timestamp - lastWheelTimestamp > 0.25 {
            flushWheel()
            wheelRemainder = 0
        }
        lastWheelTimestamp = timestamp
        wheelTarget = nextTarget; wheelPoint = point; wheelModifiers = modifiers
        let lineHeight = max(1, getOptimalFrameSize().height / CGFloat(max(1, getTerminal().rows)))
        let lines = precise ? delta / Double(lineHeight) : delta * 3
        if wheelRemainder * lines < 0 { wheelRemainder = 0 }
        wheelRemainder += min(max(lines, -120), 120)
        let whole = Int(wheelRemainder.rounded(.towardZero))
        wheelRemainder -= Double(whole)
        pendingWheelLines = min(max(pendingWheelLines + whole, -256), 256)
        guard pendingWheelLines != 0, wheelTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(flushWheel), userInfo: nil, repeats: false)
        wheelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func flushWheel() {
        wheelTimer?.invalidate(); wheelTimer = nil
        let lines = pendingWheelLines; pendingWheelLines = 0
        guard lines != 0, let wheelTarget, wheelTarget == target(modifiers: wheelModifiers) else { return }
        let terminal = getTerminal()
        switch wheelTarget {
        case .history:
            if lines > 0 { scrollUp(lines: lines) } else { scrollDown(lines: -lines) }
        case .cursor(let application):
            let arrow = "\u{1b}" + (application ? "O" : "[") + (lines > 0 ? "A" : "B")
            send(Array(String(repeating: arrow, count: min(abs(lines), 64)).utf8))
        case .mouse:
            let lineHeight = max(1, getOptimalFrameSize().height / CGFloat(max(1, terminal.rows)))
            let cellWidth = max(1, ("W" as NSString).size(withAttributes: [.font: font]).width)
            let x = min(max(wheelPoint.x, 0), bounds.width)
            let y = min(max(bounds.height - wheelPoint.y, 0), bounds.height)
            let column = min(max(Int(x / cellWidth), 0), terminal.cols - 1)
            let row = min(max(Int(y / lineHeight), 0), terminal.rows - 1)
            let button = terminal.encodeButton(button: lines > 0 ? 4 : 5, release: false,
                shift: wheelModifiers.contains(.shift), meta: wheelModifiers.contains(.option), control: wheelModifiers.contains(.control))
            for _ in 0..<min(abs(lines), 64) {
                terminal.sendEvent(buttonFlags: button, x: column, y: row, pixelX: Int(x) + 1, pixelY: Int(y) + 1)
            }
        }
    }

    private func target(modifiers: NSEvent.ModifierFlags) -> WheelTarget? {
        let terminal = getTerminal()
        if allowMouseReporting && !modifiers.contains(.shift) {
            let mode: Int
            switch terminal.mouseMode {
            case .off: mode = 0
            case .x10: mode = 1
            case .vt200: mode = 2
            case .buttonEventTracking: mode = 3
            case .anyEvent: mode = 4
            }
            if mode != 0 { return .mouse(alternate: terminal.isCurrentBufferAlternate, mode: mode) }
        }
        if terminal.isCurrentBufferAlternate {
            return modifiers.contains(.shift) ? nil : .cursor(application: terminal.applicationCursor)
        }
        return .history
    }

    private func resetWheel() {
        wheelTimer?.invalidate(); wheelTimer = nil
        wheelRemainder = 0; pendingWheelLines = 0; wheelTarget = nil
    }
}
