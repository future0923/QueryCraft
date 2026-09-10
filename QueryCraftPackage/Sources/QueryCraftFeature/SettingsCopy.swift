struct SettingsCopy {
    private let isChinese: Bool

    init(language: ApplicationLanguage) {
        isChinese = language.usesSimplifiedChinese
    }

    var settings: String { text("设置", "Settings") }
    var back: String { text("返回", "Back") }
    var forward: String { text("前进", "Forward") }
    var allCurrentFeaturesFree: String {
        text("当前所有功能免费", "All current features are free")
    }

    func title(for tab: SettingsTab) -> String {
        switch tab {
        case .general:
            text("通用", "General")
        case .license:
            text("许可证", "License")
        case .appearance:
            text("外观", "Appearance")
        case .editor:
            text("编辑器", "Editor")
        case .query:
            text("查询", "Query")
        case .data:
            text("数据", "Data")
        case .plugins:
            text("插件", "Plugins")
        }
    }

    var databaseDriverPluginsSection: String {
        text("数据库驱动", "Database Drivers")
    }
    var checkPluginUpdates: String {
        text("检查插件更新", "Check for Plugin Updates")
    }
    var checkingPluginUpdates: String {
        text("正在检查插件更新...", "Checking for plugin updates...")
    }
    var pluginUpdatesChecked: String {
        text("已检查所有插件。", "All plugins have been checked.")
    }
    var pluginSearchPlaceholder: String { text("搜索插件", "Search Plugins") }
    var pluginInstalled: String { text("已安装", "Installed") }
    var pluginNotInstalled: String { text("未安装", "Not Installed") }
    var pluginUnavailable: String { text("暂不可用", "Temporarily Unavailable") }
    var pluginUpToDate: String { text("已是最新版本", "Up to Date") }
    var pluginUpdateAvailable: String { text("有可用更新", "Update Available") }
    var pluginUpdateReady: String {
        text("更新已下载，重新启动 QueryCraft 后生效。", "The update is downloaded and will take effect after restarting QueryCraft.")
    }
    var installPlugin: String { text("安装", "Install") }
    var updatePlugin: String { text("更新", "Update") }
    var retryPluginOperation: String { text("重试", "Retry") }
    var uninstallPlugin: String { text("卸载", "Uninstall") }
    var morePluginActions: String { text("更多操作", "More Actions") }
    var pluginOperationFailed: String { text("插件操作失败", "Plugin Operation Failed") }
    var uninstallPluginTitle: String { text("卸载插件？", "Uninstall Plugin?") }
    func uninstallPluginMessage(_ name: String) -> String {
        text(
            "将从这台 Mac 移除 \(name) 插件。连接配置不会被删除，请先关闭正在使用它的工作区。",
            "The \(name) plugin will be removed from this Mac. Connection profiles will be kept. Close workspaces using it first."
        )
    }
    func installedPluginVersion(_ version: String) -> String {
        text("已安装 \(version)", "Installed \(version)")
    }
    func availablePluginVersion(_ version: String) -> String {
        text("版本 \(version)", "Version \(version)")
    }
    func pluginVersionUpdate(from installed: String, to available: String) -> String {
        text(
            "已安装 \(installed) · \(available) 可用",
            "Installed \(installed) · \(available) available"
        )
    }

    var languageSection: String { text("语言", "Language") }
    var settingsLanguage: String { text("应用语言", "Application language") }
    var settingsLanguageDescription: String {
        text(
            "选择 QueryCraft 界面使用的语言。",
            "Choose the language used throughout QueryCraft.")
    }

    var languageRestartNotice: String {
        text(
            "重新启动 QueryCraft 后，语言更改将完全生效。",
            "Restart QueryCraft for the language change to take full effect."
        )
    }

    func title(for language: ApplicationLanguage) -> String {
        switch language {
        case .system:
            text("跟随系统", "System Default")
        case .simplifiedChinese:
            "简体中文"
        case .english:
            "English"
        }
    }

    var startupSection: String { text("启动", "Startup") }
    var onLaunch: String { text("启动时", "On launch") }
    var onLaunchDescription: String {
        text(
            "恢复上次工作区窗口，或每次都显示欢迎窗口。",
            "Restore previous workspace windows, or always show the Welcome Window.")
    }

    func title(for behavior: ApplicationStartupBehavior) -> String {
        switch behavior {
        case .restoreWorkspaces:
            text("恢复上次工作区", "Restore Previous Workspaces")
        case .showWelcomeWindow:
            text("显示欢迎窗口", "Show Welcome Window")
        }
    }

    var appearanceSection: String { text("外观", "Appearance") }
    var interfaceSection: String { text("界面", "Interface") }
    var appearance: String { text("界面外观", "Appearance") }
    var appearanceDescription: String {
        text(
            "跟随系统外观，或固定使用浅色或深色模式。",
            "Follow the system appearance, or always use Light or Dark mode.")
    }

    func title(for appearance: ApplicationAppearance) -> String {
        switch appearance {
        case .system:
            text("系统", "System")
        case .light:
            text("浅色", "Light")
        case .dark:
            text("深色", "Dark")
        }
    }

    var restoreGeneralDefaults: String { text("恢复通用默认值", "Restore General Defaults") }

    var softwareUpdateSection: String { text("软件更新", "Software Update") }
    var automaticallyCheckForUpdates: String {
        text("自动检查更新", "Automatically check for updates")
    }
    var automaticallyCheckForUpdatesDescription: String {
        text(
            "有新版本时显示通知，并允许直接安装和重新启动。",
            "Notify when a new version is available, then install and relaunch directly."
        )
    }
    var checkForUpdates: String { text("检查更新...", "Check for Updates...") }

    var licenseStatusSection: String { text("许可证状态", "License Status") }
    var licenseStatus: String { text("状态", "Status") }
    var checkingLicense: String { text("正在检查", "Checking") }
    var developmentAccess: String { text("开发版本", "Development Build") }
    var freeTrial: String { text("30 天免费试用", "30-Day Free Trial") }
    var licenseActive: String { text("已激活", "Active") }
    var offlineAccess: String { text("离线宽限期", "Offline Grace Period") }
    var expires: String { text("到期时间", "Expires") }
    var plan: String { text("套餐", "Plan") }
    var deviceLimit: String { text("设备上限", "Device Limit") }
    var offlineAccessUntil: String { text("离线可用至", "Offline Access Until") }
    var checkLicenseStatus: String { text("检查许可证状态", "Check License Status") }
    var activateLicenseSection: String { text("激活", "Activation") }
    var licenseKey: String { text("许可证密钥", "License Key") }
    var licenseKeyPlaceholder: String { "QC-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" }
    var activateLicense: String { text("激活许可证", "Activate License") }
    var purchaseLicense: String { text("购买许可证...", "Purchase License...") }
    var licenseActivationDescription: String {
        text(
            "输入购买后收到的许可证密钥。",
            "Enter the license key you received after purchase."
        )
    }
    var activatingLicense: String { text("正在激活...", "Activating...") }
    var deactivateLicense: String { text("停用此设备", "Deactivate This Mac") }
    var deactivateLicenseConfirmation: String {
        text(
            "停用后将释放一个设备名额，此 Mac 会恢复为试用或受限模式。",
            "Deactivation releases one device slot. This Mac returns to trial or Restricted Mode."
        )
    }
    var licenseActionFailed: String { text("无法更新许可证", "Unable to Update License") }
    var ok: String { text("好", "OK") }

    func title(for plan: LicensePlan) -> String {
        switch plan {
        case .trial:
            freeTrial
        case .monthly:
            text("月度", "Monthly")
        case .halfYear:
            text("半年", "Half-Year")
        case .annual:
            text("年度", "Annual")
        case .perpetual:
            text("永久", "Perpetual")
        }
    }

    func title(for reason: LicenseRestrictionReason) -> String {
        switch reason {
        case .trialExpired:
            text("试用已到期", "Trial Expired")
        case .licenseExpired:
            text("许可证已到期", "License Expired")
        case .licenseSuspended:
            text("许可证已暂停", "License Suspended")
        case .activationMissing:
            text("需要重新激活", "Activation Required")
        case .validationRequired:
            text("需要联网验证", "Online Validation Required")
        case .configurationInvalid:
            text("许可证配置无效", "Invalid License Configuration")
        case .serviceUnavailable:
            text("许可证服务不可用", "License Service Unavailable")
        }
    }

    func title(for state: LicenseState) -> String {
        switch state {
        case .loading:
            checkingLicense
        case .unrestrictedDevelopment:
            developmentAccess
        case .trial:
            freeTrial
        case .paid:
            licenseActive
        case .offlineGrace:
            offlineAccess
        case let .restricted(reason):
            title(for: reason)
        }
    }

    func systemImage(for state: LicenseState) -> String {
        switch state {
        case .loading:
            "clock"
        case .unrestrictedDevelopment:
            "hammer"
        case .trial:
            "hourglass"
        case .paid:
            "checkmark.seal.fill"
        case .offlineGrace:
            "wifi.slash"
        case .restricted:
            "lock.fill"
        }
    }

    func deviceCount(_ count: Int) -> String {
        text("最多 \(count) 台 Mac", "Up to \(count) Macs")
    }

    func message(for failure: LicenseActionFailure) -> String {
        switch failure {
        case .invalidLicenseKey:
            text("许可证密钥无效。", "The license key is invalid.")
        case .expired:
            text("许可证已经到期。", "The license has expired.")
        case .suspended:
            text("许可证已经暂停。", "The license has been suspended.")
        case .activationLimitReached:
            text("已达到此许可证的设备上限。", "This license has reached its device limit.")
        case .activationMissing:
            text("此 Mac 没有可用的激活记录。", "This Mac does not have an active license slot.")
        case .serviceUnavailable:
            text("暂时无法连接许可证服务。", "The license service is temporarily unavailable.")
        case .secureStorageUnavailable:
            text("无法访问钥匙串。", "Keychain is unavailable.")
        case .invalidServerResponse:
            text("许可证服务返回了无效数据。", "The license service returned invalid data.")
        }
    }

    var editorFontSection: String { text("编辑器字体", "Editor Font") }
    var dataGridFontSection: String { text("数据表格字体", "Data Grid Font") }
    var editorFont: String { text("编辑器字体", "Editor font") }
    var dataGridFont: String { text("数据表格字体", "Data grid font") }
    var editorFontDescription: String {
        text("SQL 编辑器使用的等宽字体。", "The monospaced font used in SQL editors.")
    }
    var systemMonospaced: String { "System Mono" }
    var fontFamily: String { text("字体族", "Font Family") }
    var fontSize: String { text("大小", "Size") }
    var fontSizeDescription: String {
        text("SQL 编辑器文字大小，单位为磅。", "SQL editor text size in points.")
    }
    var previewSection: String { text("预览", "Preview") }
    var restoreAppearanceDefaults: String {
        text("恢复外观默认值", "Restore Appearance Defaults")
    }

    var indentationSection: String { text("缩进", "Indentation") }
    var indentWith: String { text("缩进方式", "Indent with") }
    var indentWithDescription: String {
        text(
            "按 Tab 或格式化 SQL 时插入空格或制表符。",
            "Insert spaces or tab characters when indenting or formatting SQL.")
    }

    func title(for style: EditorIndentationStyle) -> String {
        switch style {
        case .spaces:
            text("空格", "Spaces")
        case .tabs:
            text("制表符", "Tabs")
        }
    }

    var indentWidth: String { text("缩进宽度", "Indent width") }
    var indentWidthDescription: String {
        text("使用空格时，每一级缩进包含的空格数量。", "The number of spaces used for each indentation level.")
    }

    func indentationWidthTitle(_ width: Int) -> String {
        text("\(width) 个空格", "\(width) spaces")
    }

    var completionSection: String { text("代码补全", "Completion") }
    var acceptSuggestionWith: String { text("确认补全键", "Accept suggestion with") }
    var acceptSuggestionWithDescription: String {
        text("选择用哪个按键插入当前选中的补全内容。", "Choose which key inserts the selected completion item.")
    }

    func title(for key: EditorCompletionKey) -> String {
        switch key {
        case .returnKey:
            text("回车键", "Return")
        case .tab:
            "Tab"
        case .returnOrTab:
            text("回车键或 Tab", "Return or Tab")
        }
    }

    var formattingSection: String { text("格式化", "Formatting") }
    var sqlKeywordCase: String { text("SQL 关键字大小写", "SQL keyword case") }
    var sqlKeywordCaseDescription: String {
        text(
            "执行“格式化 SQL”时转换关键字；“保留”不会改变原始大小写。",
            "Applied by Format SQL. Preserve keeps the original keyword case.")
    }

    func title(for keywordCase: SQLKeywordCase) -> String {
        switch keywordCase {
        case .uppercase:
            text("大写", "UPPERCASE")
        case .lowercase:
            text("小写", "lowercase")
        case .preserve:
            text("保留", "Preserve")
        }
    }

    var restoreEditorDefaults: String { text("恢复编辑器默认值", "Restore Editor Defaults") }

    var queryExecutionSection: String { text("执行", "Execution") }
    var queryTimeout: String { text("查询超时", "Query timeout") }
    var queryTimeoutDescription: String {
        text(
            "每条语句允许执行的最长时间。",
            "The maximum time allowed for each statement."
        )
    }

    func title(for option: QueryTimeoutOption) -> String {
        switch option {
        case .unlimited:
            text("不限时", "Unlimited")
        case .seconds30:
            text("30 秒", "30 seconds")
        case .seconds60:
            text("60 秒", "60 seconds")
        case .seconds120:
            text("120 秒", "120 seconds")
        }
    }

    var queryResultRowLimit: String {
        text("结果行数上限", "Result row limit")
    }
    var queryResultRowLimitDescription: String {
        text(
            "限制每条语句在本地显示和保存的结果行数。",
            "Limits the result rows displayed and stored locally for each statement."
        )
    }

    func title(for limit: QueryResultRowLimit) -> String {
        switch limit {
        case .unlimited:
            text("不限制", "No limit")
        case .rows100:
            text("100 行", "100 rows")
        case .rows500:
            text("500 行", "500 rows")
        case .rows1_000:
            text("1,000 行", "1,000 rows")
        case .rows5_000:
            text("5,000 行", "5,000 rows")
        case .rows10_000:
            text("10,000 行", "10,000 rows")
        case .rows50_000:
            text("50,000 行", "50,000 rows")
        case .rows100_000:
            text("100,000 行", "100,000 rows")
        case .rows500_000:
            text("500,000 行", "500,000 rows")
        }
    }

    var querySafetySection: String { text("安全", "Safety") }
    var confirmDangerousSQL: String {
        text("执行危险请求前确认", "Confirm dangerous requests")
    }
    var confirmDangerousSQLDescription: String {
        text(
            "执行 TRUNCATE 等危险 SQL，以及 Elasticsearch 批量写入、索引删除或管理请求前要求确认。",
            "Requires confirmation for dangerous SQL such as TRUNCATE and for Elasticsearch bulk writes, index deletions, or administrative requests."
        )
    }
    var restoreQueryDefaults: String {
        text("恢复查询默认值", "Restore Query Defaults")
    }

    var dangerousSQLAlertTitle: String {
        text("确认执行危险 SQL？", "Run dangerous SQL?")
    }
    var dangerousSQLAlertMessage: String {
        text(
            "此查询包含 UPDATE、DELETE、DROP 或 TRUNCATE，执行后可能修改或删除数据。",
            "This query contains UPDATE, DELETE, DROP, or TRUNCATE and may modify or delete data."
        )
    }
    var executeDangerousSQL: String { text("执行", "Run") }
    var cancel: String { text("取消", "Cancel") }

    var tableDataSection: String { text("表数据", "Table Data") }
    var defaultPageSize: String { text("默认每页行数", "Default page size") }
    var defaultPageSizeDescription: String {
        text("打开表数据时每次向数据库请求的行数。", "The number of rows requested when opening Table Data.")
    }
    var alternatingRows: String { text("交替显示行背景", "Alternating row backgrounds") }
    var alternatingRowsDescription: String {
        text(
            "使用深浅交替的背景，便于横向查看宽表。", "Use alternating backgrounds to make wide rows easier to follow."
        )
    }
    var displayNullAs: String { text("NULL 显示方式", "Display NULL as") }
    var displayNullAsDescription: String {
        text(
            "只改变显示和复制内容，不会修改数据库中的值。",
            "Changes display and copied text only. Stored database values are not modified.")
    }

    func title(for style: TableNullDisplayStyle) -> String {
        switch style {
        case .uppercase:
            "NULL"
        case .lowercase:
            "null"
        case .empty:
            text("空单元格", "Empty Cell")
        }
    }

    var displayEmptyStringAs: String {
        text("空字符串显示方式", "Display empty strings as")
    }
    var displayEmptyStringAsDescription: String {
        text(
            "只改变空字符串的显示和复制内容，不会影响 NULL。",
            "Changes display and copied text for empty strings only. NULL is unaffected."
        )
    }

    func title(for style: TableEmptyStringDisplayStyle) -> String {
        switch style {
        case .uppercase:
            "EMPTY"
        case .lowercase:
            "empty"
        case .empty:
            text("空单元格", "Empty Cell")
        }
    }

    var copySection: String { text("复制", "Copy") }
    var includeColumnNames: String { text("复制时包含列名", "Include column names with Copy") }
    var includeColumnNamesDescription: String {
        text(
            "使用标准复制命令时，把列名作为第一行。",
            "Add column names as the first row when using the standard Copy command.")
    }
    var redisSection: String { "Redis" }
    var automaticallyResolveRedisKeyTypes: String {
        text("自动识别可见 Key 类型", "Detect visible Key types automatically")
    }
    var automaticallyResolveRedisKeyTypesDescription: String {
        text(
            "批量识别侧栏当前显示的 Key。关闭后，打开具体 Key 时仍会识别其类型。",
            "Detect Key types currently visible in the sidebar as a batch. Opening a Key still detects its type when this is off."
        )
    }
    var redisKeyTypeBatchSize: String {
        text("每批最多 Key 数", "Maximum Keys per batch")
    }
    var redisKeyTypeBatchSizeDescription: String {
        text(
            "每个 Pipeline 最多包含的 TYPE 命令数。较大的批次减少往返，但会增加单次 Redis 工作量。",
            "The maximum number of TYPE commands in each pipeline. Larger batches reduce round trips but increase work per Redis request."
        )
    }
    var restoreDataDefaults: String { text("恢复数据默认值", "Restore Data Defaults") }

    private func text(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }
}
