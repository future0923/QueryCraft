import AppKit
import Observation

@MainActor
@Observable
public final class ApplicationPreferences {
    public static let shared = ApplicationPreferences(
        userDefaults: .standard,
        appliesApplicationAppearance: true
    )

    var applicationLanguage: ApplicationLanguage {
        didSet {
            defaults.set(
                applicationLanguage.rawValue,
                forKey: Key.applicationLanguage
            )
            applicationLanguage.apply(to: defaults)
        }
    }

    var startupBehavior: ApplicationStartupBehavior {
        didSet {
            defaults.set(startupBehavior.rawValue, forKey: Key.startupBehavior)
        }
    }

    var appearance: ApplicationAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyApplicationAppearance()
        }
    }

    var automaticallyChecksForUpdates: Bool {
        didSet {
            defaults.set(
                automaticallyChecksForUpdates,
                forKey: Key.automaticallyChecksForUpdates
            )
        }
    }

    var editorFontFamily: String {
        didSet {
            defaults.set(editorFontFamily, forKey: Key.editorFontFamily)
        }
    }

    var editorFontSize: Double {
        didSet {
            let validValue = Self.clamped(
                editorFontSize.rounded(),
                to: 11...18
            )
            guard validValue == editorFontSize else {
                editorFontSize = validValue
                return
            }
            defaults.set(editorFontSize, forKey: Key.editorFontSize)
        }
    }

    var dataGridFontFamily: String {
        didSet {
            defaults.set(dataGridFontFamily, forKey: Key.dataGridFontFamily)
        }
    }

    var dataGridFontSize: Double {
        didSet {
            let validValue = Self.clamped(
                dataGridFontSize.rounded(),
                to: 11...18
            )
            guard validValue == dataGridFontSize else {
                dataGridFontSize = validValue
                return
            }
            defaults.set(dataGridFontSize, forKey: Key.dataGridFontSize)
        }
    }

    var editorIndentationStyle: EditorIndentationStyle {
        didSet {
            defaults.set(
                editorIndentationStyle.rawValue,
                forKey: Key.editorIndentationStyle
            )
        }
    }

    var editorIndentationWidth: Int {
        didSet {
            guard Self.supportedIndentationWidths.contains(
                editorIndentationWidth
            ) else {
                editorIndentationWidth = 4
                return
            }
            defaults.set(
                editorIndentationWidth,
                forKey: Key.editorIndentationWidth
            )
        }
    }

    var editorCompletionKey: EditorCompletionKey {
        didSet {
            defaults.set(
                editorCompletionKey.rawValue,
                forKey: Key.editorCompletionKey
            )
        }
    }

    var sqlKeywordCase: SQLKeywordCase {
        didSet {
            defaults.set(sqlKeywordCase.rawValue, forKey: Key.sqlKeywordCase)
        }
    }

    var queryTimeout: QueryTimeoutOption {
        didSet {
            defaults.set(queryTimeout.rawValue, forKey: Key.queryTimeout)
        }
    }

    var queryResultRowLimit: QueryResultRowLimit {
        didSet {
            defaults.set(
                queryResultRowLimit.rawValue,
                forKey: Key.queryResultRowLimit
            )
        }
    }

    var confirmsDangerousSQL: Bool {
        didSet {
            defaults.set(
                confirmsDangerousSQL,
                forKey: Key.confirmsDangerousSQL
            )
        }
    }

    var tableDataPageSize: Int {
        didSet {
            defaults.set(tableDataPageSize, forKey: Key.tableDataPageSize)
        }
    }

    var usesAlternatingTableRows: Bool {
        didSet {
            defaults.set(
                usesAlternatingTableRows,
                forKey: Key.usesAlternatingTableRows
            )
        }
    }

    var tableNullDisplayStyle: TableNullDisplayStyle {
        didSet {
            defaults.set(
                tableNullDisplayStyle.rawValue,
                forKey: Key.tableNullDisplayStyle
            )
        }
    }

    var tableEmptyStringDisplayStyle: TableEmptyStringDisplayStyle {
        didSet {
            defaults.set(
                tableEmptyStringDisplayStyle.rawValue,
                forKey: Key.tableEmptyStringDisplayStyle
            )
        }
    }

    var copyIncludesColumnNames: Bool {
        didSet {
            defaults.set(
                copyIncludesColumnNames,
                forKey: Key.copyIncludesColumnNames
            )
        }
    }

    var automaticallyResolvesVisibleRedisKeyTypes: Bool {
        didSet {
            defaults.set(
                automaticallyResolvesVisibleRedisKeyTypes,
                forKey: Key.automaticallyResolvesVisibleRedisKeyTypes
            )
        }
    }

    var redisVisibleKeyTypeBatchSize: Int {
        didSet {
            guard Self.supportedRedisVisibleKeyTypeBatchSizes.contains(
                redisVisibleKeyTypeBatchSize
            ) else {
                redisVisibleKeyTypeBatchSize = 50
                return
            }
            defaults.set(
                redisVisibleKeyTypeBatchSize,
                forKey: Key.redisVisibleKeyTypeBatchSize
            )
        }
    }

    private let defaults: UserDefaults
    private let appliesApplicationAppearance: Bool

    init(
        userDefaults: UserDefaults,
        appliesApplicationAppearance: Bool = false
    ) {
        defaults = userDefaults
        self.appliesApplicationAppearance = appliesApplicationAppearance
        let storedApplicationLanguage = Self.value(
            ApplicationLanguage.self,
            forKey: Key.applicationLanguage,
            in: userDefaults,
            default: .system
        )
        applicationLanguage = storedApplicationLanguage
        storedApplicationLanguage.apply(to: userDefaults)
        startupBehavior = Self.value(
            ApplicationStartupBehavior.self,
            forKey: Key.startupBehavior,
            in: userDefaults,
            default: .restoreWorkspaces
        )
        appearance = Self.value(
            ApplicationAppearance.self,
            forKey: Key.appearance,
            in: userDefaults,
            default: .system
        )
        automaticallyChecksForUpdates =
            userDefaults.object(
                forKey: Key.automaticallyChecksForUpdates
            ) as? Bool ?? true
        editorFontFamily =
            userDefaults.string(
                forKey: Key.editorFontFamily
            ) ?? ""
        editorFontSize = Self.clamped(
            (
                userDefaults.object(forKey: Key.editorFontSize) as? Double
                    ?? Double(NSFont.systemFontSize)
            ).rounded(),
            to: 11...18
        )
        dataGridFontFamily =
            userDefaults.string(
                forKey: Key.dataGridFontFamily
            ) ?? ""
        dataGridFontSize = Self.clamped(
            (
                userDefaults.object(forKey: Key.dataGridFontSize) as? Double
                    ?? Double(NSFont.systemFontSize)
            ).rounded(),
            to: 11...18
        )
        editorIndentationStyle = Self.value(
            EditorIndentationStyle.self,
            forKey: Key.editorIndentationStyle,
            in: userDefaults,
            default: .spaces
        )
        let storedIndentationWidth =
            userDefaults.object(
                forKey: Key.editorIndentationWidth
            ) as? Int ?? 4
        editorIndentationWidth =
            Self.supportedIndentationWidths.contains(storedIndentationWidth)
            ? storedIndentationWidth
            : 4
        editorCompletionKey = Self.value(
            EditorCompletionKey.self,
            forKey: Key.editorCompletionKey,
            in: userDefaults,
            default: .returnOrTab
        )
        sqlKeywordCase = Self.value(
            SQLKeywordCase.self,
            forKey: Key.sqlKeywordCase,
            in: userDefaults,
            default: .uppercase
        )
        queryTimeout = Self.value(
            QueryTimeoutOption.self,
            forKey: Key.queryTimeout,
            in: userDefaults,
            default: .seconds60
        )
        queryResultRowLimit = Self.value(
            QueryResultRowLimit.self,
            forKey: Key.queryResultRowLimit,
            in: userDefaults,
            default: .rows1_000
        )
        confirmsDangerousSQL =
            userDefaults.object(
                forKey: Key.confirmsDangerousSQL
            ) as? Bool ?? true
        let storedPageSize =
            userDefaults.object(
                forKey: Key.tableDataPageSize
            ) as? Int
        tableDataPageSize =
            Self.supportedPageSizes.contains(storedPageSize ?? 0)
            ? storedPageSize ?? 200
            : 200
        usesAlternatingTableRows =
            userDefaults.object(
                forKey: Key.usesAlternatingTableRows
            ) as? Bool ?? true
        tableNullDisplayStyle = Self.value(
            TableNullDisplayStyle.self,
            forKey: Key.tableNullDisplayStyle,
            in: userDefaults,
            default: .uppercase
        )
        tableEmptyStringDisplayStyle = Self.value(
            TableEmptyStringDisplayStyle.self,
            forKey: Key.tableEmptyStringDisplayStyle,
            in: userDefaults,
            default: .uppercase
        )
        copyIncludesColumnNames =
            userDefaults.object(
                forKey: Key.copyIncludesColumnNames
            ) as? Bool ?? false
        automaticallyResolvesVisibleRedisKeyTypes =
            userDefaults.object(
                forKey: Key.automaticallyResolvesVisibleRedisKeyTypes
            ) as? Bool ?? true
        let storedRedisTypeBatchSize = userDefaults.object(
            forKey: Key.redisVisibleKeyTypeBatchSize
        ) as? Int
        redisVisibleKeyTypeBatchSize =
            Self.supportedRedisVisibleKeyTypeBatchSizes.contains(
                storedRedisTypeBatchSize ?? 0
            )
            ? storedRedisTypeBatchSize ?? 50
            : 50
    }

    public static func initialize() {
        _ = shared
    }

    public var interfaceLocale: Locale {
        ApplicationLanguage.activeInterfaceLanguage.locale
    }

    public var settingsWindowTitle: String {
        SettingsCopy(language: .activeInterfaceLanguage).settings
    }

    func editorFont() -> NSFont {
        Self.monospacedFont(
            family: editorFontFamily,
            size: CGFloat(editorFontSize)
        )
    }

    func dataGridFont() -> NSFont {
        Self.monospacedFont(
            family: dataGridFontFamily,
            size: CGFloat(dataGridFontSize)
        )
    }

    var queryExecutionOptions: QueryExecutionOptions {
        QueryExecutionOptions(
            statementTimeout: queryTimeout.duration,
            maximumResultRows: queryResultRowLimit.maximumRows
        )
    }

    private static func monospacedFont(
        family: String,
        size: CGFloat
    ) -> NSFont {
        guard !family.isEmpty else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: 5,
            size: size
        ) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func resetGeneral() {
        applicationLanguage = .system
        startupBehavior = .restoreWorkspaces
        automaticallyChecksForUpdates = true
    }

    func resetAppearance() {
        appearance = .system
        editorFontFamily = ""
        editorFontSize = Double(NSFont.systemFontSize)
        dataGridFontFamily = ""
        dataGridFontSize = Double(NSFont.systemFontSize)
    }

    func resetEditor() {
        editorIndentationStyle = .spaces
        editorIndentationWidth = 4
        editorCompletionKey = .returnOrTab
        sqlKeywordCase = .uppercase
    }

    func resetQuery() {
        queryTimeout = .seconds60
        queryResultRowLimit = .rows1_000
        confirmsDangerousSQL = true
    }

    func resetData() {
        tableDataPageSize = 200
        usesAlternatingTableRows = true
        tableNullDisplayStyle = .uppercase
        tableEmptyStringDisplayStyle = .uppercase
        copyIncludesColumnNames = false
        automaticallyResolvesVisibleRedisKeyTypes = true
        redisVisibleKeyTypeBatchSize = 50
    }

    func applyApplicationAppearance() {
        guard appliesApplicationAppearance else { return }
        NSApplication.shared.appearance = appearance.appKitAppearance
    }

    private static let supportedPageSizes = [50, 100, 200, 500, 1_000]
    private static let supportedIndentationWidths = [2, 4, 6, 8]
    static let supportedRedisVisibleKeyTypeBatchSizes = [
        10, 25, 50, 100, 200, 500,
    ]

    private static func value<T>(
        _ type: T.Type,
        forKey key: String,
        in defaults: UserDefaults,
        default defaultValue: T
    ) -> T where T: RawRepresentable, T.RawValue == String {
        guard let rawValue = defaults.string(forKey: key),
            let value = T(rawValue: rawValue)
        else {
            return defaultValue
        }
        return value
    }

    private static func clamped<T: Comparable>(
        _ value: T,
        to range: ClosedRange<T>
    ) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private enum Key {
        static let applicationLanguage = "preferences.general.applicationLanguage"
        static let startupBehavior = "preferences.general.startupBehavior"
        static let appearance = "preferences.general.appearance"
        static let automaticallyChecksForUpdates =
            "preferences.general.automaticallyChecksForUpdates"
        static let editorFontFamily = "preferences.editor.fontFamily"
        static let editorFontSize = "preferences.editor.fontSize"
        static let dataGridFontFamily =
            "preferences.appearance.dataGridFontFamily"
        static let dataGridFontSize =
            "preferences.appearance.dataGridFontSize"
        static let editorIndentationStyle =
            "preferences.editor.indentationStyle"
        static let editorIndentationWidth =
            "preferences.editor.indentationWidth"
        static let editorCompletionKey = "preferences.editor.completionKey"
        static let sqlKeywordCase = "preferences.editor.sqlKeywordCase"
        static let queryTimeout = "preferences.query.timeout"
        static let queryResultRowLimit = "preferences.query.resultRowLimit"
        static let confirmsDangerousSQL =
            "preferences.query.confirmsDangerousSQL"
        static let tableDataPageSize = "preferences.data.pageSize"
        static let usesAlternatingTableRows =
            "preferences.data.usesAlternatingRows"
        static let tableNullDisplayStyle =
            "preferences.data.nullDisplayStyle"
        static let tableEmptyStringDisplayStyle =
            "preferences.data.emptyStringDisplayStyle"
        static let copyIncludesColumnNames =
            "preferences.data.copyIncludesColumnNames"
        static let automaticallyResolvesVisibleRedisKeyTypes =
            "preferences.data.redisAutomaticallyResolvesVisibleKeyTypes"
        static let redisVisibleKeyTypeBatchSize =
            "preferences.data.redisVisibleKeyTypeBatchSize"
    }
}
