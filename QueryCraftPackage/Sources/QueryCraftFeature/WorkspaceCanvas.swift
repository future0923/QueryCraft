import AppKit
import SwiftUI

extension NSColor {
    /// Opaque base surfaces. Keep native light colours and a softer dark canvas.
    static let queryCraftDarkCanvas = NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 24 / 255, alpha: 1)
    static let queryCraftCanvas = NSColor(name: "QueryCraftCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .queryCraftDarkCanvas : .textBackgroundColor
    }
    static let queryCraftWindowCanvas = NSColor(name: "QueryCraftWindowCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .queryCraftDarkCanvas : .windowBackgroundColor
    }
    static let queryCraftPanelCanvas = NSColor(name: "QueryCraftPanelCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .queryCraftDarkCanvas : .controlBackgroundColor
    }
}

extension View {
    func workspaceBarBackground() -> some View { modifier(WorkspaceBarBackground()) }
}

private struct WorkspaceBarBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            if scheme == .dark { Color(nsColor: .queryCraftDarkCanvas) }
            else { Rectangle().fill(.bar) }
        }
    }
}

struct WorkspaceCanvasBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            // Split-view hosting controllers inset their content below the native
            // titlebar. Paint that inset too, without moving the sidebar controls.
            if scheme == .dark { Color(nsColor: .queryCraftDarkCanvas).ignoresSafeArea() }
        }
    }
}
