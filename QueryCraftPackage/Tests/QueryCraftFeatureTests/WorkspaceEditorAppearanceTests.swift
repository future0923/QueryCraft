import AppKit
import Testing
@testable import QueryCraftFeature

@Suite("Workspace Editor Appearance")
struct WorkspaceEditorAppearanceTests {
    @Test("Editor colors resolve independently for light and dark appearance")
    func resolvesAdaptiveEditorColors() {
        let light = WorkspaceEditorTheme.make(for: .aqua)
        let dark = WorkspaceEditorTheme.make(for: .darkAqua)

        #expect(luminance(light.background) > luminance(dark.background))
        #expect(
            contrastRatio(
                foreground: dark.text.color,
                background: dark.background
            ) >= 4.5
        )
        #expect(
            contrastRatio(
                foreground: light.text.color,
                background: light.background
            ) >= 4.5
        )
    }

    private func contrastRatio(
        foreground: NSColor,
        background: NSColor
    ) -> CGFloat {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return 0
        }
        return 0.2126 * component(rgb.redComponent)
            + 0.7152 * component(rgb.greenComponent)
            + 0.0722 * component(rgb.blueComponent)
    }

    private func component(_ value: CGFloat) -> CGFloat {
        value <= 0.03928
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}
