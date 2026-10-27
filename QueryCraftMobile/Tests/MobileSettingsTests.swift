import Foundation
import SwiftUI
import Testing
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileSettingsTests {
    private func isolated(_ body: (MobilePreferences, UserDefaults) throws -> Void) throws {
        let name = "MobileSettingsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(MobilePreferences(defaults: defaults), defaults)
    }

    @Test func settingsPersistAcrossRecreationAndResetOnlyTheirSection() throws {
        try isolated { settings, defaults in
            settings.appearance = .dark; settings.dataGridFontSize = 18
            settings.tableDataPageSize = 500; settings.usesAlternatingTableRows = false
            settings.showsColumnDetails = false; settings.showsInspectorDetails = false
            settings.formatsTimestamps = false; settings.nullStyle = .lowercase; settings.emptyStringStyle = .uppercase
            settings.dataExport.csvDelimiter = .tab; settings.dataExport.sqlInsertBatchSize = 37
            let restored = MobilePreferences(defaults: defaults)
            #expect(restored.colorScheme == .dark)
            #expect(restored.gridStyle == settings.gridStyle)
            #expect(restored.tableDataPageSize == 500 && !restored.showsInspectorDetails)
            #expect(restored.dataExport == settings.dataExport)
            restored.resetAppearance()
            #expect(restored.appearance == .system && restored.dataGridFontSize == 15)
            #expect(restored.tableDataPageSize == 500 && restored.dataExport.sqlInsertBatchSize == 37)
            restored.resetData()
            #expect(restored.tableDataPageSize == 100 && restored.formatsTimestamps)
            #expect(restored.dataExport.sqlInsertBatchSize == 37)
        }
    }

    @Test func invalidStoredValuesAndRuntimeInputsUseSafeDefaults() throws {
        try isolated { settings, defaults in
            settings.dataGridFontSize = .nan; #expect(settings.dataGridFontSize == 15)
            settings.dataGridFontSize = 200; #expect(settings.dataGridFontSize == 18)
            settings.dataGridFontSize = -10; #expect(settings.dataGridFontSize == 11)
            settings.tableDataPageSize = -1; #expect(settings.tableDataPageSize == 100)
            defaults.set("invalid", forKey: "preferences.general.appearance")
            defaults.set(999, forKey: "preferences.data.pageSize")
            defaults.set(Data("bad archive".utf8), forKey: "preferences.data.export")
            let restored = MobilePreferences(defaults: defaults)
            #expect(restored.colorScheme == nil && restored.tableDataPageSize == 100)
            #expect(restored.dataExport.isValid)
            settings.dataExport.sqlInsertBatchSize = 0
            #expect(MobilePreferences(defaults: defaults).dataExport.isValid)
        }
    }

    @Test func defaultsReachAllSQLDriversAndESWithoutChangingExistingPages() throws {
        try isolated { settings, _ in
            settings.tableDataPageSize = 200
            for driver in [MobileDriver.mysql, .postgresql, .doris] {
                let configuration = MobileSQLConfiguration(host: "unused", port: 1, username: "", password: nil, database: "db", tlsMode: .disabled, driver: driver)
                let browser = MobileBrowserModel(configuration: configuration, preferences: settings)
                #expect(browser.pageSize == 200)
                settings.tableDataPageSize = 50
                #expect(browser.pageSize == 200)
                settings.tableDataPageSize = 200
            }
            let profile = MobileConnectionProfile(id: UUID(), name: "ES", host: "unused", port: 1, username: "", database: "", tlsMode: .disabled, remembersPassword: false, requiresPassword: false, driver: .elasticsearch)
            let es = MobileElasticsearchWorkspace(profile: profile, password: nil, preferences: settings)
            #expect(es.pageSize == 200)
            settings.tableDataPageSize = 500
            #expect(es.pageSize == 200)
        }
    }

    @Test func existingExportCapturesDefaultsAndDoesNotOverwriteGlobalPreferences() throws {
        try isolated { settings, _ in
            settings.dataExport.csvDelimiter = .tab; settings.dataExport.sqlIncludesDatabaseName = true
            settings.dataExport.prettyPrintsJSON = false
            let snapshot = MobileDataExportSnapshot(data: .init(columns: ["value"], rows: [["=1+2"], [nil]]), name: "data", scopeDescription: "current")
            let export = MobileDataExportModel(snapshot: snapshot, defaults: settings)
            #expect(export.preferences == settings.dataExport)
            export.preferences.csvDelimiter = .semicolon
            #expect(settings.dataExport.csvDelimiter == .tab)
            settings.dataExport.csvDelimiter = .pipe
            #expect(export.preferences.csvDelimiter == .semicolon)
            let options = export.preferences.options(for: .csv)
            let request = try snapshot.request(options: options)
            #expect(request.options.csvDelimiter == .semicolon)
            #expect(snapshot.data.cell(row: 0, column: 0) == .text("=1+2"))
            #expect(snapshot.data.cell(row: 1, column: 0) == .null)
        }
    }

    @Test func gridSettingChangeReconfiguresSameRevisionPreservesScrollSelectionAndRawValues() throws {
        try isolated { settings, _ in
            let preview = MobileSQLPreview(result: .init(columns: ["created_at", "nullable", "empty"], columnTypes: ["bigint", "text", "text"],
                rows: (0..<100).map { _ in ["1700000000", nil, ""] }))
            let data = MobileGridData(preview: preview)
            let viewport = MobileGridViewport()
            let grid = MobileDataGrid(preferences: settings, data: data, revision: "same", widthKey: UUID().uuidString, viewport: viewport) { _, _ in }
            let coordinator = grid.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
            view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
            grid.apply(to: view, coordinator: coordinator)
            view.setContentOffset(CGPoint(x: 0, y: 440), animated: false)
            let selected = IndexPath(item: 0, section: 12)
            view.selectItem(at: selected, animated: false, scrollPosition: [])
            settings.formatsTimestamps = false; settings.showsColumnDetails = false
            settings.dataGridFontSize = 18; settings.usesAlternatingTableRows = false
            settings.nullStyle = .lowercase; settings.emptyStringStyle = .uppercase
            grid.apply(to: view, coordinator: coordinator)
            #expect(view.contentOffset.y == 440)
            #expect(view.indexPathsForSelectedItems == [selected])
            let cell = coordinator.collectionView(view, cellForItemAt: selected)
            #expect(cell.accessibilityLabel == "created_at，1700000000")
            let nullable = coordinator.collectionView(view, cellForItemAt: IndexPath(item: 1, section: 12))
            #expect(nullable.accessibilityLabel == "nullable，null")
            let empty = coordinator.collectionView(view, cellForItemAt: IndexPath(item: 2, section: 12))
            #expect(empty.accessibilityLabel == "empty，EMPTY")
            #expect(cell.contentView.subviews.compactMap { $0 as? UILabel }.contains { $0.font.pointSize == 18 })
            #expect(coordinator.timestampDisplay.set(.seconds, column: 0))
            #expect(coordinator.timestampDisplay.preview(.text("1700000000"), column: 0, maximumCharacterCount: 200, style: settings.gridStyle) != "1700000000")
            #expect(data.cell(row: 11, column: 0) == .text("1700000000"))
        }
    }
}
