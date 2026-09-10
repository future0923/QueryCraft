import AppKit
import Foundation
import Testing

@testable import QueryCraftFeature

@MainActor
struct ApplicationPreferencesTests {
    @Test
    func usesProductDefaultsWhenNothingWasStored() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = ApplicationPreferences(userDefaults: defaults)

        #expect(preferences.applicationLanguage == .system)
        #expect(preferences.startupBehavior == .restoreWorkspaces)
        #expect(preferences.appearance == .system)
        #expect(preferences.automaticallyChecksForUpdates)
        #expect(preferences.editorFontFamily.isEmpty)
        #expect(
            preferences.editorFontSize == Double(NSFont.systemFontSize)
        )
        #expect(preferences.dataGridFontFamily.isEmpty)
        #expect(
            preferences.dataGridFontSize == Double(NSFont.systemFontSize)
        )
        #expect(preferences.editorIndentationStyle == .spaces)
        #expect(preferences.editorIndentationWidth == 4)
        #expect(preferences.editorCompletionKey == .returnOrTab)
        #expect(preferences.sqlKeywordCase == .uppercase)
        #expect(preferences.queryTimeout == .seconds60)
        #expect(preferences.queryResultRowLimit == .rows1_000)
        #expect(preferences.confirmsDangerousSQL)
        #expect(preferences.tableDataPageSize == 200)
        #expect(preferences.usesAlternatingTableRows)
        #expect(preferences.tableNullDisplayStyle == .uppercase)
        #expect(preferences.tableEmptyStringDisplayStyle == .uppercase)
        #expect(!preferences.copyIncludesColumnNames)
        #expect(preferences.automaticallyResolvesVisibleRedisKeyTypes)
        #expect(preferences.redisVisibleKeyTypeBatchSize == 50)
    }

    @Test
    func persistsChangedPreferencesAcrossInstances() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = ApplicationPreferences(userDefaults: defaults)

        preferences.applicationLanguage = .simplifiedChinese
        preferences.startupBehavior = .showWelcomeWindow
        preferences.appearance = .dark
        preferences.automaticallyChecksForUpdates = false
        preferences.editorFontFamily = "Menlo"
        preferences.editorFontSize = 16
        preferences.dataGridFontFamily = "Monaco"
        preferences.dataGridFontSize = 15
        preferences.editorIndentationStyle = .tabs
        preferences.editorIndentationWidth = 6
        preferences.editorCompletionKey = .tab
        preferences.sqlKeywordCase = .lowercase
        preferences.queryTimeout = .seconds120
        preferences.queryResultRowLimit = .rows5_000
        preferences.confirmsDangerousSQL = false
        preferences.tableDataPageSize = 500
        preferences.usesAlternatingTableRows = false
        preferences.tableNullDisplayStyle = .empty
        preferences.tableEmptyStringDisplayStyle = .lowercase
        preferences.copyIncludesColumnNames = true
        preferences.automaticallyResolvesVisibleRedisKeyTypes = false
        preferences.redisVisibleKeyTypeBatchSize = 200

        let restored = ApplicationPreferences(userDefaults: defaults)

        #expect(restored.applicationLanguage == .simplifiedChinese)
        #expect(restored.startupBehavior == .showWelcomeWindow)
        #expect(restored.appearance == .dark)
        #expect(!restored.automaticallyChecksForUpdates)
        #expect(restored.editorFontFamily == "Menlo")
        #expect(restored.editorFontSize == 16)
        #expect(restored.dataGridFontFamily == "Monaco")
        #expect(restored.dataGridFontSize == 15)
        #expect(restored.editorIndentationStyle == .tabs)
        #expect(restored.editorIndentationWidth == 6)
        #expect(restored.editorCompletionKey == .tab)
        #expect(restored.sqlKeywordCase == .lowercase)
        #expect(restored.queryTimeout == .seconds120)
        #expect(restored.queryResultRowLimit == .rows5_000)
        #expect(!restored.confirmsDangerousSQL)
        #expect(restored.tableDataPageSize == 500)
        #expect(!restored.usesAlternatingTableRows)
        #expect(restored.tableNullDisplayStyle == .empty)
        #expect(restored.tableEmptyStringDisplayStyle == .lowercase)
        #expect(restored.copyIncludesColumnNames)
        #expect(!restored.automaticallyResolvesVisibleRedisKeyTypes)
        #expect(restored.redisVisibleKeyTypeBatchSize == 200)
    }

    @Test
    func appliesSelectedLanguageToAppleLanguagesForNextLaunch() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = ApplicationPreferences(userDefaults: defaults)

        #expect(
            defaults.persistentDomain(forName: suiteName)?["AppleLanguages"]
                == nil
        )

        preferences.applicationLanguage = .simplifiedChinese
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])

        preferences.applicationLanguage = .english
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])

        preferences.applicationLanguage = .system
        #expect(
            defaults.persistentDomain(forName: suiteName)?["AppleLanguages"]
                == nil
        )
    }

    @Test
    func resettingGeneralRestoresSystemLanguage() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        preferences.applicationLanguage = .english
        preferences.startupBehavior = .showWelcomeWindow
        preferences.appearance = .dark
        preferences.automaticallyChecksForUpdates = false

        preferences.resetGeneral()

        #expect(preferences.applicationLanguage == .system)
        #expect(preferences.startupBehavior == .restoreWorkspaces)
        #expect(preferences.appearance == .dark)
        #expect(preferences.automaticallyChecksForUpdates)
    }

    @Test
    func resettingAppearanceRestoresThemeAndFonts() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        preferences.appearance = .dark
        preferences.editorFontFamily = "Menlo"
        preferences.editorFontSize = 18
        preferences.dataGridFontFamily = "Monaco"
        preferences.dataGridFontSize = 16

        preferences.resetAppearance()

        #expect(preferences.appearance == .system)
        #expect(preferences.editorFontFamily.isEmpty)
        #expect(
            preferences.editorFontSize == Double(NSFont.systemFontSize)
        )
        #expect(preferences.dataGridFontFamily.isEmpty)
        #expect(
            preferences.dataGridFontSize == Double(NSFont.systemFontSize)
        )
    }

    @Test
    func repairsOutOfRangeStoredValues() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(100, forKey: "preferences.editor.fontSize")
        defaults.set(
            100,
            forKey: "preferences.appearance.dataGridFontSize"
        )
        defaults.set(0, forKey: "preferences.editor.indentationWidth")
        defaults.set("invalid", forKey: "preferences.query.timeout")
        defaults.set("invalid", forKey: "preferences.query.resultRowLimit")
        defaults.set(123, forKey: "preferences.data.pageSize")
        defaults.set(
            123,
            forKey: "preferences.data.redisVisibleKeyTypeBatchSize"
        )

        let preferences = ApplicationPreferences(userDefaults: defaults)

        #expect(preferences.editorFontSize == 18)
        #expect(preferences.dataGridFontSize == 18)
        #expect(preferences.editorIndentationWidth == 4)
        #expect(preferences.queryTimeout == .seconds60)
        #expect(preferences.queryResultRowLimit == .rows1_000)
        #expect(preferences.tableDataPageSize == 200)
        #expect(preferences.redisVisibleKeyTypeBatchSize == 50)
    }

    @Test
    func resettingQueryRestoresExecutionAndSafetyDefaults() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        preferences.queryTimeout = .unlimited
        preferences.queryResultRowLimit = .unlimited
        preferences.confirmsDangerousSQL = false

        preferences.resetQuery()

        #expect(preferences.queryTimeout == .seconds60)
        #expect(preferences.queryResultRowLimit == .rows1_000)
        #expect(preferences.confirmsDangerousSQL)
        #expect(
            preferences.queryExecutionOptions
                == QueryExecutionOptions(
                    statementTimeout: .seconds(60),
                    maximumResultRows: 1_000
                )
        )
    }

    @Test
    func clampsOutOfRangeEditorValuesWhenChanged() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = ApplicationPreferences(userDefaults: defaults)

        preferences.editorFontSize = 100
        preferences.dataGridFontSize = 100
        preferences.editorIndentationWidth = 0

        #expect(preferences.editorFontSize == 18)
        #expect(preferences.dataGridFontSize == 18)
        #expect(preferences.editorIndentationWidth == 4)

        let restored = ApplicationPreferences(userDefaults: defaults)
        #expect(restored.editorFontSize == 18)
        #expect(restored.dataGridFontSize == 18)
        #expect(restored.editorIndentationWidth == 4)
    }

    @Test
    func resettingDataRestoresRedisTypeDetectionDefaults() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        preferences.automaticallyResolvesVisibleRedisKeyTypes = false
        preferences.redisVisibleKeyTypeBatchSize = 500

        preferences.resetData()

        #expect(preferences.automaticallyResolvesVisibleRedisKeyTypes)
        #expect(preferences.redisVisibleKeyTypeBatchSize == 50)

        preferences.redisVisibleKeyTypeBatchSize = 123
        #expect(preferences.redisVisibleKeyTypeBatchSize == 50)
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ApplicationPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
