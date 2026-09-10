import AppKit
import SwiftUI

struct WorkspaceQueryRowLimitMenuControl: NSViewRepresentable {
    @Binding var selection: QueryResultRowLimit
    let width: CGFloat
    let isEnabled: Bool

    private static let menuSegmentWidth: CGFloat = 26

    func makeCoordinator() -> Coordinator {
        Coordinator(control: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: [title, ""],
            trackingMode: .momentary,
            target: context.coordinator,
            action: nil
        )
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.setImage(
            NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: AppCopy.current.text(
                    "显示行数选项",
                    "Show row limit options"
                )
            ),
            forSegment: 1
        )
        control.setImageScaling(.scaleProportionallyDown, forSegment: 1)
        control.setAccessibilityIdentifier("queryResultRowLimitPicker")
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: true)
        popUpButton.translatesAutoresizingMaskIntoConstraints = false
        popUpButton.isBordered = false
        (popUpButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popUpButton.preferredEdge = .minY
        popUpButton.setAccessibilityIdentifier("queryResultRowLimitPicker")
        popUpButton.setAccessibilityLabel(
            AppCopy.current.text("结果行数上限", "Result Row Limit")
        )
        control.addSubview(popUpButton)
        NSLayoutConstraint.activate([
            popUpButton.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            popUpButton.trailingAnchor.constraint(
                equalTo: control.trailingAnchor
            ),
            popUpButton.topAnchor.constraint(equalTo: control.topAnchor),
            popUpButton.bottomAnchor.constraint(equalTo: control.bottomAnchor),
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
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    private func update(
        _ control: NSSegmentedControl,
        coordinator: Coordinator
    ) {
        control.setLabel(title, forSegment: 0)
        control.setWidth(width - Self.menuSegmentWidth, forSegment: 0)
        control.setWidth(Self.menuSegmentWidth, forSegment: 1)
        control.setEnabled(isEnabled, forSegment: 0)
        control.setEnabled(isEnabled, forSegment: 1)
        control.setToolTip(help, forSegment: 0)
        control.setToolTip(help, forSegment: 1)
        control.setAccessibilityLabel(
            AppCopy.current.text("结果行数上限", "Result Row Limit")
        )
        coordinator.synchronizeMenu()
        coordinator.popUpButton?.isEnabled = isEnabled
    }

    private var title: String {
        copy.title(for: selection)
    }

    private var help: String {
        AppCopy.current.text(
            "当前查询页的结果行数上限",
            "Result row limit for this query tab"
        )
    }

    private var copy: SettingsCopy {
        SettingsCopy(
            language: .activeInterfaceLanguage
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var control: WorkspaceQueryRowLimitMenuControl
        private(set) var menu: NSMenu?
        weak var popUpButton: NSPopUpButton?

        init(control: WorkspaceQueryRowLimitMenuControl) {
            self.control = control
        }

        func synchronizeMenu() {
            if menu?.items.count != QueryResultRowLimit.allCases.count + 1 {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(
                    NSMenuItem(
                        title: "",
                        action: nil,
                        keyEquivalent: ""
                    )
                )
                for (index, limit) in QueryResultRowLimit.allCases.enumerated() {
                    let item = NSMenuItem(
                        title: "",
                        action: #selector(selectLimit(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = index
                    item.representedObject = limit.rawValue
                    menu.addItem(item)
                }
                self.menu = menu
                popUpButton?.menu = menu
            }

            guard let menu else { return }
            let copy = SettingsCopy(
                language: .activeInterfaceLanguage
            )
            for (index, limit) in QueryResultRowLimit.allCases.enumerated() {
                let item = menu.items[index + 1]
                item.title = copy.title(for: limit)
                item.state = limit == control.selection ? .on : .off
                item.isEnabled = control.isEnabled
            }
        }

        @objc
        private func selectLimit(_ sender: NSMenuItem) {
            guard
                QueryResultRowLimit.allCases.indices.contains(sender.tag)
            else {
                return
            }
            control.selection = QueryResultRowLimit.allCases[sender.tag]
        }
    }
}
