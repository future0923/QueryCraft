import AppKit
import SwiftUI

struct RedisKeyCreateMenu: View {
    let isEnabled: Bool
    let createKey: @MainActor @Sendable (RedisKeyType) -> Void

    var body: some View {
        IconMenuRepresentable(
            title: AppCopy.current.text("新增 Key", "New Key"),
            isEnabled: isEnabled,
            createKey: createKey
        )
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .frame(width: 24, height: 24)
    }
}

private struct IconMenuRepresentable: NSViewRepresentable {
    let title: String
    let isEnabled: Bool
    let createKey: @MainActor @Sendable (RedisKeyType) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(createKey: createKey)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            frame: NSRect(x: 0, y: 0, width: 24, height: 24)
        )
        button.bezelStyle = .regularSquare
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: title
        )
        button.target = context.coordinator
        button.action = #selector(Coordinator.presentMenu(_:))
        configure(button)
        return button
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSButton,
        context: Context
    ) -> CGSize? {
        CGSize(width: 24, height: 24)
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.createKey = createKey
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    @MainActor
    final class Coordinator: NSObject {
        var createKey: @MainActor @Sendable (RedisKeyType) -> Void

        init(createKey: @escaping @MainActor @Sendable (RedisKeyType) -> Void) {
            self.createKey = createKey
        }

        @objc func presentMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for type in WorkspaceRedisNewKeyDraft.creatableTypes {
                let item = NSMenuItem(
                    title: type.displayName,
                    action: #selector(selectType(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = type.rawValue
                menu.addItem(item)
            }
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 4),
                in: sender
            )
        }

        @objc func selectType(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let type = RedisKeyType(rawValue: rawValue)
            else { return }
            createKey(type)
        }
    }
}
