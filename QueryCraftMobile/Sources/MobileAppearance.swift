import SwiftUI
import UIKit

/// Feedback belongs to the scrolling form, never a persistent bottom panel.
/// Reserve the indicator/text space so loading transitions do not move fields.
struct MobileFormStatus: View {
    let message: String
    var isBusy = false
    var isError = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView().controlSize(.small).opacity(isBusy ? 1 : 0)
                .accessibilityHidden(!isBusy)
            Text(message).font(.caption).foregroundStyle(isError ? Color.red : .secondary)
                .lineLimit(3, reservesSpace: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("formStatus")
    }
}

/// Shared chrome for both phone and tablet. Editor palettes and semantic
/// warning/error colours remain owned by their existing components.
@MainActor enum MobileAppearance {
    // Resolve from the view environment, never a sidebar's elevated UIKit trait.
    static func canvas(for scheme: ColorScheme) -> Color { scheme == .dark ? .black : .white }
    static var tint: Color { Color(uiColor: .label) }
    static var onTint: Color { Color(uiColor: .systemBackground) }
    static var selection: Color { Color(uiColor: selectionColor) }
    static var selectionColor: UIColor { UIColor.label.withAlphaComponent(0.12) }
    static var swipeAction: Color { Color(uiColor: .darkGray) }
}

extension View {
    @MainActor func mobileCanvas() -> some View { modifier(MobileCanvas()) }
    @MainActor func mobileAppearance() -> some View {
        tint(MobileAppearance.tint)
            .toggleStyle(MobileSwitchStyle())
            .background(MobileWindowTint().frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false))
    }
}

// Keep the standard platform switch; only its on colour is independent of
// the neutral navigation tint. Locally styled button toggles still take priority.
private struct MobileSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(Color(uiColor: .systemGreen))
    }
}

private struct MobileCanvas: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let canvas = MobileAppearance.canvas(for: scheme)
        content.scrollContentBackground(.hidden)
            .background(canvas)
            .toolbarBackground(canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
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
