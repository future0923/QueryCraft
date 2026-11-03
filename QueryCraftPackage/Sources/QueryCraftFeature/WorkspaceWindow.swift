import AppKit

@MainActor
final class WorkspaceWindow: NSWindow {
    private var titlebarAppearanceObservation: NSKeyValueObservation?

    func configureTitlebarBackground() {
        // On macOS 26 a transparent titlebar can leave an opaque white sidebar
        // section over its toolbar items after fullscreen or sidebar transitions.
        // Let AppKit draw that section in dark mode; retain the existing light
        // appearance and the native toolbar's controls, sizing and placement.
        guard #available(macOS 26.0, *) else { return }
        titlebarAppearanceObservation = observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateTitlebarBackground()
            }
        }
        updateTitlebarBackground()
    }

    private func updateTitlebarBackground() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let shouldBeTransparent = !isDark
        if titlebarAppearsTransparent != shouldBeTransparent {
            titlebarAppearsTransparent = shouldBeTransparent
        }
    }

    func closeAfterApproval() {
        close()
    }
}
