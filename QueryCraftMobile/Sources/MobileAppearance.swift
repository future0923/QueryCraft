import SwiftUI
import UIKit

/// Shared chrome for both phone and tablet. Editor palettes and semantic
/// warning/error colours remain owned by their existing components.
@MainActor enum MobileAppearance {
    static var tint: Color { Color(uiColor: .label) }
    static var onTint: Color { Color(uiColor: .systemBackground) }
    static var selection: Color { Color(uiColor: selectionColor) }
    static var selectionColor: UIColor { UIColor.label.withAlphaComponent(0.12) }
    static var swipeAction: Color { Color(uiColor: .darkGray) }
}

extension View {
    @MainActor func mobileAppearance() -> some View {
        tint(MobileAppearance.tint)
            .background(MobileWindowTint().frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false))
    }
}

// SwiftUI controls use the environment tint; UIKit controls inherit from the
// actual scene window. Explicit editor cursor/theme colours still take priority.
private struct MobileWindowTint: UIViewRepresentable {
    func makeUIView(context: Context) -> TintAnchor { TintAnchor() }
    func updateUIView(_ view: TintAnchor, context: Context) { view.window?.tintColor = .label }
    final class TintAnchor: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.tintColor = .label
        }
    }
}
