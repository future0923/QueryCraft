import AppKit
import SwiftUI

/// Mapping uses the same searchable native popover as SQL Structure.
@MainActor
final class WorkspaceMappingGridOptionPresenter {
    private let model = WorkspaceDatabaseSchemaGridOptionPopoverModel()
    private var items: [NSMenuItem] = []
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 220, height: 320)
        popover.contentViewController = NSHostingController(rootView: WorkspaceDatabaseSchemaGridOptionPopover(
            model: model,
            select: { [weak self] value in self?.select(value) },
            dismiss: { [weak self] in self?.close() }
        ))
        return popover
    }()

    func show(items: [NSMenuItem], title: String, rect: NSRect, in view: NSView) {
        close()
        self.items = items
        model.prepare(options: items.enumerated().map { .init(value: String($0.offset), title: $0.element.title) },
                      selectedValue: items.firstIndex(where: { $0.state == .on }).map(String.init),
                      accessibilityTitle: title)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover.close()
        items = []
    }

    private func select(_ value: String) {
        guard let index = Int(value), items.indices.contains(index), items[index].isEnabled else { return }
        let item = items[index]
        close()
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
}
