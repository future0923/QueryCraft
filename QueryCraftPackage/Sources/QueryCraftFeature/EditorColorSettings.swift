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
    case classic, ocean, soft
    var id: Self { self }

    func colors(for mode: EditorColorMode) -> [EditorColorRole: String] {
        // In EditorColorRole order. Saturated syntax accents, quiet surfaces, and readable comments.
        // Light palettes use deeper accents; dark palettes use brighter accents from the same hue families.
        // Preserve at least 4.5:1 text contrast on normal, current-line and blended selection backgrounds.
        let values: [String]
        switch (self, mode) {
        case (.classic, .light):
            values = ["24283B", "8728B8", "006A61", "1660A6", "944B10", "624FAC", "236B31", "9D4410", "AD2860", "2F6383", "7F4797", "765A15", "9A3D6E", "535F72", "525F73", "FFFFFF", "F0F4FC", "579AFF", "8050CC"]
        case (.classic, .dark):
            values = ["E6EDF8", "F186D0", "65D3C1", "79B7F5", "F2D373", "BDA0EF", "A6D978", "F5AB65", "F18CA7", "85CBE5", "D9A4EF", "E8C680", "EB8CBD", "A4B5D0", "9DACC2", "1E1E1E", "282828", "335B9A", "D9A4EF"]
        case (.ocean, .light):
            values = ["18344A", "6334DD", "005AB3", "006576", "006856", "9423AD", "1E6A1C", "9F3A00", "AE1C56", "135BA8", "8B349E", "755700", "A22970", "465E72", "495E6E", "F5FAFF", "E5F0FB", "379FF5", "006DDE"]
        case (.ocean, .dark):
            values = ["E0F3FF", "BBA8FF", "55BDFF", "3EDFD8", "59F0AA", "DC9BFF", "AEED65", "FFB454", "FF93BD", "8DCFFF", "F29CEC", "F4DC70", "E997EF", "93BCD8", "9BB8CC", "1E1E1E", "282828", "146B8B", "48D9FF"]
        case (.soft, .light):
            values = ["37312E", "A82377", "3B54BE", "00686B", "984400", "7C3BBB", "3D681A", "A33A17", "AF2258", "1F5F99", "983586", "755900", "A3345A", "665B55", "665B51", "FFF9F0", "F5EADC", "D196CE", "BC347C"]
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
        boldKeywords = true
        italicComments = true
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
