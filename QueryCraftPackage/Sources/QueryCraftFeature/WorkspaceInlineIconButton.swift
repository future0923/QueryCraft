import AppKit
import SwiftUI

struct WorkspaceInlineIconButton: View {
    private static let sideLength: CGFloat = 24

    let systemImageName: String
    let title: String
    let isEnabled: Bool
    let action: @MainActor @Sendable () -> Void

    init(
        systemImageName: String,
        title: String,
        isEnabled: Bool = true,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.systemImageName = systemImageName
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        ButtonRepresentable(
            systemImageName: systemImageName,
            title: title,
            isEnabled: isEnabled,
            action: action
        )
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .frame(width: Self.sideLength, height: Self.sideLength)
    }
}

private struct ButtonRepresentable: NSViewRepresentable {
    let systemImageName: String
    let title: String
    let isEnabled: Bool
    let action: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, isEnabled: isEnabled)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 24,
                height: 24
            )
        )
        button.bezelStyle = .regularSquare
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction(_:))
        configure(button, coordinator: context.coordinator)
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
        context.coordinator.action = action
        context.coordinator.isEnabled = isEnabled
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: NSButton, coordinator: Coordinator) {
        if coordinator.systemImageName != systemImageName
            || coordinator.title != title
        {
            button.image = NSImage(
                systemSymbolName: systemImageName,
                accessibilityDescription: title
            )
        }
        if coordinator.title != title {
            button.toolTip = title
            button.setAccessibilityLabel(title)
        }
        coordinator.systemImageName = systemImageName
        coordinator.title = title
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor @Sendable () -> Void
        var isEnabled: Bool
        var systemImageName: String?
        var title: String?

        init(
            action: @escaping @MainActor @Sendable () -> Void,
            isEnabled: Bool
        ) {
            self.action = action
            self.isEnabled = isEnabled
        }

        @objc func performAction(_ sender: NSButton) {
            guard isEnabled else { return }
            action()
        }
    }
}
