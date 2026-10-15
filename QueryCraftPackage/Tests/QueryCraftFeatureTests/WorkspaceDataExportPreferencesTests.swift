import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceDataExportPreferencesTests {
    @Test("Export settings survive a restart and reject invalid batch sizes")
    func persistsAndValidates() throws {
        let name = "ExportPreferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        #expect(preferences.dataExport.sqlInsertBatchSize == 1_000)
        preferences.dataExport.sqlInsertBatchSize = 237
        preferences.dataExport.csvDelimiter = .semicolon
        preferences.dataExport.jsonLayout = .lines
        preferences.dataExport.xlsxAddsAutoFilter = false
        preferences.dataExport.sqlInsertBatchSize = 0
        #expect(preferences.dataExport.sqlInsertBatchSize == 237)
        let restored = ApplicationPreferences(userDefaults: defaults)
        #expect(restored.dataExport == preferences.dataExport)
        #expect(restored.dataExport.options(for: .json).fileExtension == "jsonl")
        #expect(restored.dataExport.options(for: .sql).sqlTableName.isEmpty)
        restored.resetData()
        #expect(ApplicationPreferences(userDefaults: defaults).dataExport == WorkspaceDataExportPreferences())
    }

    @Test("Malformed stored preferences fall back to valid defaults")
    func recoversMalformedPreferences() throws {
        let name = "ExportPreferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: "preferences.data.export")
        #expect(ApplicationPreferences(userDefaults: defaults).dataExport.sqlInsertBatchSize == 1_000)
    }
}
