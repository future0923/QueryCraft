import AppKit

public extension NSColor {
    func resolved(for appearance: NSAppearance) -> NSColor {
        var resolvedColor = self
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = usingColorSpace(.deviceRGB) ?? self
        }
        return resolvedColor
    }
}
