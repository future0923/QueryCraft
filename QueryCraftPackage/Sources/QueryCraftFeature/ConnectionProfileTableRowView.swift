import AppKit

@MainActor
final class ConnectionProfileTableRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            updateHostedSelection(in: self)
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateHostedSelection(in: subview)
    }

    private func updateHostedSelection(in view: NSView) {
        if let hostingView = view as? ConnectionProfileHostingView {
            hostingView.setSelectedAppearance(isSelected)
        }
        for subview in view.subviews {
            updateHostedSelection(in: subview)
        }
    }
}
