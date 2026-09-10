import AppKit

@MainActor
final class WorkspaceRedisKeyOutlineNativeView: NSOutlineView {
    var togglePrefixAtRow: ((Int) -> Bool)?
    var contextMenuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }
        return contextMenuForRow?(clickedRow)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        if event.clickCount == 1,
           modifiers.isEmpty,
           clickedRow >= 0,
           togglePrefixAtRow?(clickedRow) == true
        {
            return
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class WorkspaceRedisKeyOutlineSelectionRowView: NSTableRowView {
    var suppressesSelectionHighlight = false

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        suppressesSelectionHighlight ? .normal : super.interiorBackgroundStyle
    }

    override var isEmphasized: Bool {
        get { true }
        set { super.isEmphasized = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !suppressesSelectionHighlight else { return }
        super.drawSelection(in: dirtyRect)
    }
}
