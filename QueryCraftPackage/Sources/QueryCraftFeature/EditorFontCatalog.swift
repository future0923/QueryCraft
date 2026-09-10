import AppKit

@MainActor
enum EditorFontCatalog {
    static let families: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = manager.font(
                withFamily: family,
                traits: [],
                weight: 5,
                size: NSFont.systemFontSize
            ) else {
                return false
            }
            return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
    }()
}
