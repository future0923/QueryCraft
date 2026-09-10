import AppKit
import SwiftUI

struct WorkspaceQuerySplitMenuControl: NSViewRepresentable {
    let title: String
    let width: CGFloat
    let isPrimaryEnabled: Bool
    let isMenuEnabled: Bool
    let help: String
    let accessibilityIdentifier: String
    let menuItems: [WorkspaceQuerySplitMenuItem]
    let primaryAction: @MainActor @Sendable () -> Void

    private static let menuSegmentWidth: CGFloat = 26

    func makeCoordinator() -> Coordinator {
        Coordinator(control: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: [title, ""],
            trackingMode: .momentary,
            target: context.coordinator,
            action: #selector(Coordinator.segmentSelected(_:))
        )
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.setImage(
            NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: "Show menu"
            ),
            forSegment: 1
        )
        control.setImageScaling(.scaleProportionallyDown, forSegment: 1)
        control.setToolTip(help, forSegment: 0)
        control.setToolTip("Show menu", forSegment: 1)
        control.setAccessibilityIdentifier(accessibilityIdentifier)
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: true)
        popUpButton.translatesAutoresizingMaskIntoConstraints = false
        popUpButton.isBordered = false
        (popUpButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popUpButton.preferredEdge = .minY
        popUpButton.setAccessibilityLabel(
            AppCopy.current.text("显示菜单", "Show Menu")
        )
        control.addSubview(popUpButton)
        NSLayoutConstraint.activate([
            popUpButton.trailingAnchor.constraint(
                equalTo: control.trailingAnchor
            ),
            popUpButton.topAnchor.constraint(equalTo: control.topAnchor),
            popUpButton.bottomAnchor.constraint(equalTo: control.bottomAnchor),
            popUpButton.widthAnchor.constraint(
                equalToConstant: Self.menuSegmentWidth
            ),
        ])
        context.coordinator.popUpButton = popUpButton
        update(control, coordinator: context.coordinator)
        return control
    }

    func updateNSView(
        _ control: NSSegmentedControl,
        context: Context
    ) {
        context.coordinator.control = self
        update(control, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSSegmentedControl,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: width,
            height: nsView.intrinsicContentSize.height
        )
    }

    private func update(
        _ control: NSSegmentedControl,
        coordinator: Coordinator
    ) {
        control.setLabel(title, forSegment: 0)
        control.setWidth(width - Self.menuSegmentWidth, forSegment: 0)
        control.setWidth(Self.menuSegmentWidth, forSegment: 1)
        control.setEnabled(isPrimaryEnabled, forSegment: 0)
        control.setEnabled(isMenuEnabled, forSegment: 1)
        control.setToolTip(help, forSegment: 0)
        control.setAccessibilityIdentifier(accessibilityIdentifier)
        coordinator.synchronizeMenu()
        coordinator.popUpButton?.isEnabled = isMenuEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var control: WorkspaceQuerySplitMenuControl
        private(set) var menu: NSMenu?
        weak var popUpButton: NSPopUpButton?

        init(control: WorkspaceQuerySplitMenuControl) {
            self.control = control
        }

        func synchronizeMenu() {
            if menu?.items.count != control.menuItems.count + 1 {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(
                    NSMenuItem(
                        title: "",
                        action: nil,
                        keyEquivalent: ""
                    )
                )
                for index in control.menuItems.indices {
                    let menuItem = NSMenuItem(
                        title: "",
                        action: #selector(menuItemSelected(_:)),
                        keyEquivalent: ""
                    )
                    menuItem.target = self
                    menuItem.tag = index
                    menu.addItem(menuItem)
                }
                self.menu = menu
                popUpButton?.menu = menu
            }

            guard let menu else { return }
            for (index, item) in control.menuItems.enumerated() {
                let menuItem = menu.items[index + 1]
                menuItem.title = item.title
                menuItem.keyEquivalent = item.keyEquivalent
                menuItem.keyEquivalentModifierMask = item.keyEquivalentModifierMask
                menuItem.isEnabled = item.isEnabled
            }
        }

        @objc
        func segmentSelected(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0:
                control.primaryAction()
            case 1:
                break
            default:
                break
            }
        }

        @objc
        private func menuItemSelected(_ sender: NSMenuItem) {
            guard control.menuItems.indices.contains(sender.tag) else { return }
            control.menuItems[sender.tag].action()
        }
    }
}
