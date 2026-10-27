import SwiftUI
import Observation
import UIKit

/// Mobile storage/consumers; export rules, display styles and appearance cases
/// are the same sources as Mac. No paths, passwords or transient selections.
@MainActor @Observable final class MobilePreferences {
    static let shared = MobilePreferences(defaults: sharedDefaults)
    private static var sharedDefaults: UserDefaults {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let owner = environment["QUERYCRAFT_PROOF_SYSTEM_OWNER"].flatMap(UUID.init(uuidString:)),
           let defaults = UserDefaults(suiteName: "QueryCraftPhysicalSettings." + owner.uuidString) {
            if environment["QUERYCRAFT_PROOF_SYSTEM_CLEANUP"] == "1" {
                defaults.removePersistentDomain(forName: "QueryCraftPhysicalSettings." + owner.uuidString)
            }
            return defaults
        }
        #endif
        return .standard
    }
    static let pageSizes = [25, 50, 100, 200, 500]
    @ObservationIgnored private let defaults: UserDefaults

    var appearance: ApplicationAppearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    var dataGridFontFamily: String { didSet { defaults.set(dataGridFontFamily, forKey: Key.fontFamily) } }
    var dataGridFontSize: Double { didSet {
        let valid = Self.validFontSize(dataGridFontSize)
        if dataGridFontSize != valid { dataGridFontSize = valid }
        defaults.set(dataGridFontSize, forKey: Key.fontSize)
    } }
    var tableDataPageSize: Int { didSet {
        if !Self.pageSizes.contains(tableDataPageSize) { tableDataPageSize = 100 }
        defaults.set(tableDataPageSize, forKey: Key.pageSize)
    } }
    var usesAlternatingTableRows: Bool { didSet { defaults.set(usesAlternatingTableRows, forKey: Key.alternatingRows) } }
    var showsColumnDetails: Bool { didSet { defaults.set(showsColumnDetails, forKey: Key.columnDetails) } }
    var showsInspectorDetails: Bool { didSet { defaults.set(showsInspectorDetails, forKey: Key.inspectorDetails) } }
    var formatsTimestamps: Bool { didSet { defaults.set(formatsTimestamps, forKey: Key.timestamps) } }
    var nullStyle: TableNullDisplayStyle { didSet { defaults.set(nullStyle.rawValue, forKey: Key.nullStyle) } }
    var emptyStringStyle: TableEmptyStringDisplayStyle { didSet { defaults.set(emptyStringStyle.rawValue, forKey: Key.emptyStyle) } }
    var dataExport: WorkspaceDataExportPreferences { didSet {
        if dataExport.isValid, let data = try? JSONEncoder().encode(dataExport) { defaults.set(data, forKey: Key.export) }
    } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(ApplicationAppearance.init(rawValue:)) ?? .system
        dataGridFontFamily = defaults.string(forKey: Key.fontFamily) ?? ""
        dataGridFontSize = Self.validFontSize(defaults.object(forKey: Key.fontSize) as? Double ?? 15)
        let size = defaults.integer(forKey: Key.pageSize)
        tableDataPageSize = Self.pageSizes.contains(size) ? size : 100
        usesAlternatingTableRows = defaults.object(forKey: Key.alternatingRows) as? Bool ?? true
        showsColumnDetails = defaults.object(forKey: Key.columnDetails) as? Bool ?? true
        showsInspectorDetails = defaults.object(forKey: Key.inspectorDetails) as? Bool ?? true
        formatsTimestamps = defaults.object(forKey: Key.timestamps) as? Bool ?? true
        nullStyle = defaults.string(forKey: Key.nullStyle).flatMap(TableNullDisplayStyle.init(rawValue:)) ?? .uppercase
        emptyStringStyle = defaults.string(forKey: Key.emptyStyle).flatMap(TableEmptyStringDisplayStyle.init(rawValue:)) ?? .empty
        dataExport = defaults.data(forKey: Key.export).flatMap { try? JSONDecoder().decode(WorkspaceDataExportPreferences.self, from: $0) }
            .flatMap { $0.isValid ? $0 : nil } ?? .init()
    }

    var colorScheme: ColorScheme? {
        switch appearance { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var gridStyle: MobileGridStyle {
        .init(fontFamily: dataGridFontFamily, fontSize: dataGridFontSize, alternatingRows: usesAlternatingTableRows,
              showsDetails: showsColumnDetails, formatsTimestamps: formatsTimestamps,
              nullText: nullStyle.displayText, emptyText: emptyStringStyle.displayText)
    }
    var validDataExport: WorkspaceDataExportPreferences {
        dataExport.isValid ? dataExport : defaults.data(forKey: Key.export)
            .flatMap { try? JSONDecoder().decode(WorkspaceDataExportPreferences.self, from: $0) }
            .flatMap { $0.isValid ? $0 : nil } ?? .init()
    }
    func resetAppearance() { appearance = .system; dataGridFontFamily = ""; dataGridFontSize = 15 }
    func resetData() {
        tableDataPageSize = 100; usesAlternatingTableRows = true
        showsColumnDetails = true; showsInspectorDetails = true; formatsTimestamps = true
        nullStyle = .uppercase; emptyStringStyle = .empty
    }
    private static func validFontSize(_ value: Double) -> Double { value.isFinite ? min(18, max(11, value.rounded())) : 15 }
    private enum Key {
        static let appearance = "preferences.general.appearance"
        static let fontFamily = "preferences.appearance.dataGridFontFamily"
        static let fontSize = "preferences.appearance.dataGridFontSize"
        static let pageSize = "preferences.data.pageSize"
        static let alternatingRows = "preferences.data.usesAlternatingRows"
        static let columnDetails = "preferences.mobile.data.showsColumnDetails"
        static let inspectorDetails = "preferences.mobile.data.showsInspectorDetails"
        static let timestamps = "preferences.data.formatsTimestamps"
        static let nullStyle = "preferences.data.nullDisplayStyle"
        static let emptyStyle = "preferences.data.emptyStringDisplayStyle"
        static let export = "preferences.data.export"
    }
}

struct MobileGridStyle: Equatable {
    var fontFamily: String
    var fontSize: Double
    var alternatingRows: Bool
    var showsDetails: Bool
    var formatsTimestamps: Bool
    var nullText: String
    var emptyText: String
    @MainActor var font: UIFont { MobileFontCatalog.font(family: fontFamily, size: fontSize) }
}

@MainActor enum MobileFontCatalog {
    static var families: [String] {
        UIFont.familyNames.filter { family in
            UIFont.fontNames(forFamilyName: family).contains { UIFont(name: $0, size: 15)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true }
        }.sorted()
    }
    static func font(family: String, size: Double) -> UIFont {
        if !family.isEmpty, let name = UIFont.fontNames(forFamilyName: family).first,
           let font = UIFont(name: name, size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
