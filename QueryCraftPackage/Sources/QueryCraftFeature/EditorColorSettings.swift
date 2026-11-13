import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Persist device-independent sRGB, never archived NSColor or appearance-dependent colors.
enum EditorHexColor {
    static func normalized(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return "#" + digits.uppercased()
    }

    #if os(iOS)
    static func color(_ hex: String) -> UIColor {
        let value = UInt32(normalized(hex)?.dropFirst() ?? "000000", radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func hex(_ color: UIColor) -> String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    #else
    static func color(_ hex: String) -> NSColor {
        let value = UInt32(normalized(hex)?.dropFirst() ?? "000000", radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(rgb.redComponent),
                      channel(rgb.greenComponent), channel(rgb.blueComponent))
    }
    #endif
}

enum EditorColorMode: String, CaseIterable, Identifiable, Sendable {
    case light, dark
    var id: Self { self }
    #if !os(iOS)
    var appearanceName: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
    #endif
}

enum EditorColorRole: String, CaseIterable, Identifiable, Sendable {
    case text, keyword, object, property, function, type, string, number, boolean
    case variable, parameter, attribute, `operator`, punctuation, comment
    case background, currentLine, selection, cursor
    case lineNumber, currentLineNumber, searchMatch, searchCurrent, searchText
    var id: Self { self }
    static let syntax: [Self] = Array(allCases.prefix(15))
    static let surface: [Self] = Array(allCases.dropFirst(15))
}

enum EditorColorPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case classic, navicat, github, xcode, catppuccin, ocean, soft
    var id: Self { self }

    var names: (chinese: String, english: String) {
        switch self {
        case .classic: ("经典", "Classic")
        case .navicat: ("Navicat", "Navicat")
        case .github: ("GitHub", "GitHub")
        case .xcode: ("Xcode", "Xcode")
        case .catppuccin: ("Catppuccin", "Catppuccin")
        case .ocean: ("海洋", "Ocean")
        case .soft: ("柔和", "Soft")
        }
    }

    /// Roles emphasized by the Bold Keywords style. Navicat and Xcode also bold some keyword-like literals.
    var boldRoles: Set<EditorColorRole> {
        switch self {
        case .navicat: [.keyword, .type, .boolean]
        case .xcode: [.keyword, .boolean]
        default: [.keyword]
        }
    }

    var boldKeywordsByDefault: Bool { ![.github, .catppuccin].contains(self) }

    var italicCommentsByDefault: Bool { [.classic, .catppuccin, .ocean, .soft].contains(self) }

    func colors(for mode: EditorColorMode) -> [EditorColorRole: String] {
        // In EditorColorRole order. Light palettes keep identifiers and operators in the text color, use bright
        // accents and light-gray comments. Navicat, GitHub (Primer), Xcode (Default) and Catppuccin (Latte/Mocha)
        // follow their originals, nudged only where EditorColorReadability requires. Every palette passes it.
        let values: [String]
        switch (self, mode) {
        case (.classic, .light):
            values = ["4B4F5A", "A23BE0", "0B9C8C", "4B4F5A", "D98200", "7B61FF", "22A33A", "F2621F", "E8457A", "4B4F5A", "B45CE0", "B88600", "4B4F5A", "4B4F5A", "A0A5AE", "FFFFFF", "F5F7FB", "579AFF", "8050CC"]
        case (.classic, .dark):
            values = ["E6EDF8", "F186D0", "65D3C1", "79B7F5", "F2D373", "BDA0EF", "A6D978", "F5AB65", "F18CA7", "85CBE5", "D9A4EF", "E8C680", "EB8CBD", "A4B5D0", "9DACC2", "1E1E1E", "282828", "335B9A", "D9A4EF"]
        case (.navicat, .light):
            values = ["535353", "1B94F6", "535353", "535353", "1B8CDA", "1B94F6", "FF3B5A", "10CC6C", "1B94F6", "535353", "535353", "1B94F6", "535353", "535353", "A3A3A3", "FFFFFF", "F7F9FC", "6AA6FF", "000000"]
        case (.navicat, .dark):
            values = ["D4D4D4", "4AA8FF", "D4D4D4", "D4D4D4", "6CB6EA", "4AA8FF", "FF6B82", "3DDC84", "4AA8FF", "D4D4D4", "D4D4D4", "4AA8FF", "D4D4D4", "D4D4D4", "969696", "1E1E1E", "282828", "2F6FB5", "D4D4D4"]
        case (.github, .light):
            values = ["1F2328", "CF222E", "953800", "1F2328", "8250DF", "CF222E", "0A3069", "0550AE", "0550AE", "1F2328", "953800", "0550AE", "CF222E", "1F2328", "59636E", "FFFFFF", "F6F8FA", "0969DA", "0969DA"]
        case (.github, .dark):
            values = ["E6EDF3", "FF7B72", "FFA657", "E6EDF3", "D2A8FF", "FF7B72", "A5D6FF", "79C0FF", "79C0FF", "E6EDF3", "FFA657", "79C0FF", "FF7B72", "E6EDF3", "8B949E", "0D1117", "161B22", "388BFD", "2F81F7"]
        case (.xcode, .light):
            values = ["262626", "9B2393", "1C464A", "262626", "6C36A9", "3900A0", "C41A16", "1C00CF", "9B2393", "262626", "262626", "815F03", "262626", "262626", "5D6C79", "FFFFFF", "E8F2FF", "4A90FF", "000000"]
        case (.xcode, .dark):
            values = ["DFDFE0", "FF7AB2", "ACF2E4", "DFDFE0", "B78BEE", "DABAFF", "FF8170", "D9C97C", "FF7AB2", "DFDFE0", "DFDFE0", "CC9768", "DFDFE0", "DFDFE0", "7F8C98", "292A30", "2F3239", "5A657A", "FFFFFF"]
        case (.catppuccin, .light):
            values = ["4C4F69", "8839EF", "DF8E1D", "4C4F69", "1E66F5", "DF8E1D", "40A02B", "FE640B", "FE640B", "4C4F69", "E64553", "DF8E1D", "04A5E5", "7C7F93", "7C7F93", "EFF1F5", "E6E9EF", "7C7F93", "1E66F5"]
        case (.catppuccin, .dark):
            values = ["CDD6F4", "CBA6F7", "F9E2AF", "CDD6F4", "89B4FA", "F9E2AF", "A6E3A1", "FAB387", "FAB387", "CDD6F4", "EBA0AC", "F9E2AF", "89DCEB", "9399B2", "9399B2", "1E1E2E", "2A2B3C", "9399B2", "F5E0DC"]
        case (.ocean, .light):
            values = ["44515E", "7653F5", "0A8AE0", "44515E", "0EA07A", "C04FE0", "5AA30F", "F08A00", "E54C8A", "44515E", "C04FE0", "B88600", "44515E", "44515E", "98A6B3", "F7FAFD", "EEF4FB", "379FF5", "006DDE"]
        case (.ocean, .dark):
            values = ["E0F3FF", "BBA8FF", "55BDFF", "3EDFD8", "59F0AA", "DC9BFF", "AEED65", "FFB454", "FF93BD", "8DCFFF", "F29CEC", "F4DC70", "E997EF", "93BCD8", "9BB8CC", "1E1E1E", "282828", "146B8B", "48D9FF"]
        case (.soft, .light):
            values = ["5B514B", "E0438F", "5778E8", "5B514B", "D97706", "9B5DE5", "4C9A2A", "EF5D3A", "E0438F", "5B514B", "9B5DE5", "B07A00", "5B514B", "5B514B", "B3A79C", "FFFBF5", "F7EFE4", "D196CE", "BC347C"]
        case (.soft, .dark):
            values = ["F2E6D8", "FF87BE", "91AEFF", "63D8CD", "FFD16B", "CEA0FF", "BAE577", "FFA366", "FF8B9F", "81C9EE", "EFA0D8", "E6D37A", "F795BA", "C4AD9A", "BDAB9E", "1E1E1E", "282828", "854568", "FF96CC"]
        }
        var colors = Dictionary(uniqueKeysWithValues: zip(EditorColorRole.allCases, values.map { "#" + $0 }))
        colors[.lineNumber] = colors[.comment]
        colors[.currentLineNumber] = colors[.text]
        colors[.searchMatch] = mode == .light ? "#F4DB92" : "#615124"
        colors[.searchCurrent] = mode == .light ? "#FFD35A" : "#FFD35A"
        colors[.searchText] = "#242000"
        return colors
    }
}

struct EditorColorPalette: Codable, Equatable, Sendable {
    private var presetID = EditorColorPreset.classic.rawValue
    private(set) var overrides: [String: String] = [:]
    var boldKeywords = true
    var italicComments = true
    init() {}

    private enum CodingKeys: String, CodingKey { case presetID, overrides, boldKeywords, italicComments }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetID = (try? container.decode(String.self, forKey: .presetID)) ?? EditorColorPreset.classic.rawValue
        overrides = (try? container.decode([String: String].self, forKey: .overrides)) ?? [:]
        boldKeywords = (try? container.decode(Bool.self, forKey: .boldKeywords)) ?? true
        italicComments = (try? container.decode(Bool.self, forKey: .italicComments)) ?? true
    }

    var preset: EditorColorPreset { EditorColorPreset(rawValue: presetID) ?? .classic }

    func isBold(_ role: EditorColorRole) -> Bool { boldKeywords && preset.boldRoles.contains(role) }

    func isItalic(_ role: EditorColorRole) -> Bool { role == .comment && italicComments }

    func hex(for role: EditorColorRole, mode: EditorColorMode) -> String {
        overrides[role.rawValue].flatMap(EditorHexColor.normalized)
            ?? preset.colors(for: mode)[role] ?? "#000000"
    }

    mutating func setHex(_ hex: String, for role: EditorColorRole) {
        guard let value = EditorHexColor.normalized(hex) else { return }
        overrides[role.rawValue] = value
    }

    mutating func reset(_ role: EditorColorRole) { overrides.removeValue(forKey: role.rawValue) }

    mutating func apply(_ preset: EditorColorPreset) {
        presetID = preset.rawValue
        overrides = [:]
        boldKeywords = preset.boldKeywordsByDefault
        italicComments = preset.italicCommentsByDefault
    }
}

struct EditorColorSettings: Codable, Equatable, Sendable {
    var light = EditorColorPalette()
    var dark = EditorColorPalette()

    init() {}

    private enum CodingKeys: String, CodingKey { case light, dark }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        light = (try? container.decode(EditorColorPalette.self, forKey: .light)) ?? .init()
        dark = (try? container.decode(EditorColorPalette.self, forKey: .dark)) ?? .init()
    }

    subscript(mode: EditorColorMode) -> EditorColorPalette {
        get { mode == .dark ? dark : light }
        set {
            if mode == .dark { dark = newValue } else { light = newValue }
        }
    }

    static func load(_ data: Data?) -> Self {
        guard let data else { return Self() }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
}
