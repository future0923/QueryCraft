import AppKit
import SwiftUI

extension NSColor {
    /// Opaque base surfaces. Keep native light colours; dark canvas is RGB zero.
    static let queryCraftCanvas = NSColor(name: "QueryCraftCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .textBackgroundColor
    }
    static let queryCraftWindowCanvas = NSColor(name: "QueryCraftWindowCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .windowBackgroundColor
    }
    static let queryCraftPanelCanvas = NSColor(name: "QueryCraftPanelCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .controlBackgroundColor
    }
}

extension View {
    func workspaceBarBackground() -> some View { modifier(WorkspaceBarBackground()) }
}

private struct WorkspaceBarBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            if scheme == .dark { Color.black }
            else { Rectangle().fill(.bar) }
        }
    }
}

struct WorkspaceCanvasBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            if scheme == .dark { Color.black }
        }
    }
}
