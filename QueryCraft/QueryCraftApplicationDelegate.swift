import AppKit
import QueryCraftFeature
import SwiftUI

@MainActor
final class QueryCraftApplicationDelegate: NSObject, NSApplicationDelegate {
    private let softwareUpdateManager = SoftwareUpdateManager.shared
    private var fallbackWelcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        softwareUpdateManager.start()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.showWelcomeWindowIfNeeded()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            showWelcomeWindowIfNeeded()
        }
        return true
    }

    private func showWelcomeWindowIfNeeded() {
        guard !NSApp.windows.contains(where: \.isVisible) else { return }
        if let fallbackWelcomeWindow {
            fallbackWelcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView()
            .environment(
                \.locale,
                ApplicationPreferences.shared.interfaceLocale
            )
            .background(WelcomeWindowConfigurator())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 460),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "QueryCraft"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        fallbackWelcomeWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
