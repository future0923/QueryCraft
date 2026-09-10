import Testing

@testable import QueryCraftFeature

struct SettingsCopyTests {
    @Test
    func providesSimplifiedChineseSettingsCopy() {
        let copy = SettingsCopy(language: .simplifiedChinese)

        #expect(copy.allCurrentFeaturesFree == "当前所有功能免费")

        #expect(copy.settings == "设置")
        #expect(copy.title(for: SettingsTab.general) == "通用")
        #expect(copy.title(for: SettingsTab.license) == "许可证")
        #expect(copy.title(for: SettingsTab.appearance) == "外观")
        #expect(copy.title(for: SettingsTab.query) == "查询")
        #expect(copy.title(for: SettingsTab.plugins) == "插件")
        #expect(copy.databaseDriverPluginsSection == "数据库驱动")
        #expect(copy.pluginUpdateReady.contains("重新启动 QueryCraft"))
        #expect(copy.settingsLanguage == "应用语言")
        #expect(copy.languageRestartNotice.contains("重新启动 QueryCraft"))
        #expect(
            copy.title(for: ApplicationStartupBehavior.restoreWorkspaces)
                == "恢复上次工作区"
        )
        #expect(copy.indentationWidthTitle(4) == "4 个空格")
        #expect(copy.acceptSuggestionWithDescription.contains("补全内容"))
        #expect(copy.includeColumnNamesDescription.contains("第一行"))
        #expect(copy.redisSection == "Redis")
        #expect(copy.automaticallyResolveRedisKeyTypes.contains("自动识别"))
        #expect(copy.redisKeyTypeBatchSizeDescription.contains("Pipeline"))
        #expect(
            copy.title(for: TableEmptyStringDisplayStyle.uppercase)
                == "EMPTY"
        )
        #expect(
            copy.title(for: TableEmptyStringDisplayStyle.empty)
                == "空单元格"
        )
        #expect(copy.systemMonospaced == "System Mono")
        #expect(copy.title(for: QueryTimeoutOption.seconds60) == "60 秒")
        #expect(copy.title(for: QueryResultRowLimit.rows1_000) == "1,000 行")
        #expect(
            copy.title(for: QueryResultRowLimit.rows500_000) == "500,000 行"
        )
        #expect(copy.confirmDangerousSQLDescription.contains("TRUNCATE"))
        #expect(copy.softwareUpdateSection == "软件更新")
        #expect(copy.checkForUpdates == "检查更新...")
        #expect(copy.freeTrial == "30 天免费试用")
        #expect(copy.licenseActivationDescription.contains("许可证密钥"))
        #expect(copy.licenseKeyPlaceholder == "QC-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX")
        #expect(copy.title(for: LicenseState.trial(expiresAt: .distantFuture)) == "30 天免费试用")
        #expect(copy.systemImage(for: LicenseState.restricted(.trialExpired)) == "lock.fill")
        #expect(copy.title(for: LicensePlan.halfYear) == "半年")
        #expect(copy.title(for: LicensePlan.perpetual) == "永久")
        #expect(copy.title(for: LicenseRestrictionReason.trialExpired) == "试用已到期")
        #expect(copy.deviceCount(3) == "最多 3 台 Mac")
    }

    @Test
    func providesEnglishSettingsCopy() {
        let copy = SettingsCopy(language: .english)

        #expect(copy.allCurrentFeaturesFree == "All current features are free")

        #expect(copy.settings == "Settings")
        #expect(copy.title(for: SettingsTab.editor) == "Editor")
        #expect(copy.title(for: SettingsTab.license) == "License")
        #expect(copy.title(for: SettingsTab.appearance) == "Appearance")
        #expect(copy.title(for: SettingsTab.query) == "Query")
        #expect(copy.title(for: SettingsTab.plugins) == "Plugins")
        #expect(copy.databaseDriverPluginsSection == "Database Drivers")
        #expect(copy.pluginUpdateReady.contains("restarting QueryCraft"))
        #expect(copy.settingsLanguage == "Application language")
        #expect(copy.languageRestartNotice.contains("Restart QueryCraft"))
        #expect(
            copy.title(for: ApplicationStartupBehavior.showWelcomeWindow)
                == "Show Welcome Window"
        )
        #expect(copy.defaultPageSizeDescription.contains("rows requested"))
        #expect(copy.automaticallyResolveRedisKeyTypes.contains("automatically"))
        #expect(copy.redisKeyTypeBatchSizeDescription.contains("TYPE commands"))
        #expect(copy.indentationWidthTitle(8) == "8 spaces")
        #expect(copy.displayNullAsDescription.contains("not modified"))
        #expect(
            copy.title(for: TableEmptyStringDisplayStyle.lowercase)
                == "empty"
        )
        #expect(
            copy.title(for: TableEmptyStringDisplayStyle.empty)
                == "Empty Cell"
        )
        #expect(copy.systemMonospaced == "System Mono")
        #expect(copy.title(for: QueryTimeoutOption.unlimited) == "Unlimited")
        #expect(copy.title(for: QueryResultRowLimit.unlimited) == "No limit")
        #expect(copy.title(for: QueryResultRowLimit.rows5_000) == "5,000 rows")
        #expect(copy.dangerousSQLAlertTitle == "Run dangerous SQL?")
        #expect(copy.softwareUpdateSection == "Software Update")
        #expect(copy.checkForUpdates == "Check for Updates...")
        #expect(copy.freeTrial == "30-Day Free Trial")
        #expect(copy.licenseActivationDescription.contains("license key"))
        #expect(copy.licenseKeyPlaceholder == "QC-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX")
        #expect(copy.title(for: LicenseState.paid(plan: .annual, expiresAt: nil, maximumActivations: 2)) == "Active")
        #expect(copy.systemImage(for: LicenseState.paid(plan: .annual, expiresAt: nil, maximumActivations: 2)) == "checkmark.seal.fill")
        #expect(copy.title(for: LicensePlan.monthly) == "Monthly")
        #expect(copy.title(for: LicensePlan.annual) == "Annual")
        #expect(
            copy.title(for: LicenseRestrictionReason.validationRequired)
                == "Online Validation Required"
        )
        #expect(copy.deviceCount(2) == "Up to 2 Macs")
    }

    @Test
    func detectsChineseSystemLanguageIdentifiers() {
        #expect(ApplicationLanguage.prefersChinese(["zh-Hans-CN"]))
        #expect(ApplicationLanguage.prefersChinese(["zh-Hant-TW"]))
        #expect(!ApplicationLanguage.prefersChinese(["en-US"]))
        #expect(!ApplicationLanguage.prefersChinese([]))
    }
}
