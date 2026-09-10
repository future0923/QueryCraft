import AppKit
import SwiftUI

struct WelcomeWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WelcomeWindowConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WelcomeWindowConfigurationView)?.configureWindow()
    }
}

@MainActor
private final class WelcomeWindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        window?.isRestorable = false
    }
}
