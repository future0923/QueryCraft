import Foundation

struct CloudSyncCopy: Sendable {
    private let isChinese: Bool

    init(isChinese: Bool) {
        self.isChinese = isChinese
    }

    #if os(macOS)
    static var current: CloudSyncCopy {
        CloudSyncCopy(isChinese: ApplicationLanguage.activeInterfaceLanguage.usesSimplifiedChinese)
    }
    #else
    /// The iPhone and iPad interface is Chinese.
    static var current: CloudSyncCopy { CloudSyncCopy(isChinese: true) }
    #endif

    private func text(_ chinese: String, _ english: String) -> String {
        #if os(macOS)
        isChinese ? chinese : english
        #else
        isChinese ? chinese.replacingOccurrences(of: "系统设置", with: "设置") : english
        #endif
    }

    var purchaseBridgePending: String {
        text("购买已生效，跨设备授权暂未同步。请稍后点“恢复购买”重试，无需再次购买。", "Your purchase is active, but cross-device access has not synced yet. Restore purchases later to retry; do not purchase again.")
    }
    var accountAccess: String { text("跨设备授权", "Cross-device Access") }
    var startSyncTrial: String { text("免费试用同步 30 天", "Try Sync Free for 30 Days") }
    var trialPeriod: String { text("试用截止", "Trial Ends") }
    var trialTerms: String { text("同一 iCloud 账户共用 30 天试用，换设备或重装不会重新计时。不会自动扣款，到期只暂停同步，本地功能和数据照常保留。", "Your iCloud account shares one 30-day trial across devices and reinstalls. No automatic charge. When it ends, only sync pauses; local features and data remain available.") }
    var trialEnded: String { text("此 iCloud 账户的 30 天试用已结束，本地功能仍可免费使用。", "This iCloud account’s 30-day trial has ended. Local features remain free.") }
    var linkLicense: String { text("将现有授权关联到当前 iCloud", "Link Existing License to Current iCloud Account") }
    var licenseLinked: String { text("授权已关联，使用同一 iCloud 账户的设备可自动识别。", "License linked. Devices using the same iCloud account can recognize your access automatically.") }
    var noLicenseToLink: String { text("请先在本机激活已有授权码，再关联 iCloud。", "Activate your existing license on this Mac before linking iCloud.") }
    var licenseAccountConflict: String { text("这份授权已关联其他 iCloud 账户。请使用原账户，或联系支持处理。", "This license is linked to another iCloud account. Use that account or contact support.") }
    var accountAccessFailed: String { text("暂时无法验证 iCloud 同步授权。请确认已登录 iCloud 且网络正常，然后重试。本地功能不受影响。", "Unable to verify iCloud sync access. Check your iCloud sign-in and connection, then try again. Local features are unaffected.") }

    var title: String { text("iCloud 同步", "iCloud Sync") }
    var syncHeadline: String { text("换台设备，接着工作", "Pick up on any device") }
    var syncOverview: String { text("连接、密码、保存的查询与代码片段，在 Mac、iPhone 和 iPad 间同步。", "Sync connections, passwords, saved queries and snippets across Mac, iPhone and iPad.") }
    var chooseSyncPlan: String { text("同步方案", "Sync Plans") }
    var trialShortTerms: String { text("同一 iCloud 账户共享试用，不自动扣款。到期仅暂停同步，本地功能永久免费。", "One trial across your iCloud devices. No automatic charge. Only sync pauses when it ends; local features stay free.") }
    var purchaseHelp: String { text("购买与授权", "Purchases and Access") }
    func planDetail(_ plan: CloudSyncPlan) -> String {
        switch plan {
        case .monthly: text("按月自动续费", "Renews monthly")
        case .halfYear: text("每 6 个月自动续费", "Renews every 6 months")
        case .annual: text("按年自动续费", "Renews yearly")
        case .perpetual: text("一次购买，永久同步", "Pay once, sync forever")
        }
    }
    var toggle: String { text("通过 iCloud 同步", "Sync with iCloud") }
    var summary: String {
        text(
            "连接配置、密码、保存的查询和代码片段会在你的 Mac、iPhone 和 iPad 之间自动同步。密码使用 iCloud 端到端加密保存。",
            "Connections, passwords, saved queries and snippets sync automatically between your Mac, iPhone and iPad. Passwords are end-to-end encrypted in iCloud."
        )
    }
    var syncNow: String { text("立即同步", "Sync Now") }
    var syncing: String { text("正在同步…", "Syncing…") }
    var off: String { text("未开启", "Off") }
    var waiting: String { text("等待同步", "Waiting to sync") }
    func lastSynced(_ date: Date) -> String {
        let time = date.formatted(date: .abbreviated, time: .shortened)
        return text("上次同步：\(time)", "Last synced \(time)")
    }
    var notSignedIn: String {
        text("这台设备没有登录 iCloud，或 iCloud Drive 已关闭。请在系统设置中登录后重试。",
             "This device is not signed in to iCloud or iCloud Drive is off. Sign in from System Settings and try again.")
    }
    var accountChanged: String {
        text("iCloud 账户已变更，同步已关闭。本机数据已保留，可以重新开启同步。",
             "The iCloud account changed, so sync was turned off. Local data was kept; turn sync on again to continue.")
    }
    var quotaExceeded: String {
        text("iCloud 储存空间已满。请在系统设置中清理 iCloud 空间或扩容，然后重试。本机数据已保留。", "iCloud storage is full. Free up iCloud space or upgrade storage in Settings, then retry. Your local data is kept.")
    }
    var networkUnavailable: String {
        text("网络不可用，恢复后会自动继续同步。", "The network is unavailable. Sync resumes automatically.")
    }
    var serviceUnavailable: String {
        text("Apple 的 iCloud 服务暂时不可用，稍后会自动重试。本机数据已保留。",
             "Apple's iCloud service is temporarily unavailable. Sync will retry later. Your local data is kept.")
    }
    var accountUnavailable: String {
        text("暂时无法访问你的 iCloud 账户。请在系统设置中检查账户状态后重试。",
             "Your iCloud account is temporarily unavailable. Check your account in Settings, then retry.")
    }
    var configurationError: String {
        text("此版本的 iCloud 同步配置异常，请更新 QueryCraft；若仍失败，请联系支持。本机数据已保留。",
             "This version has an iCloud sync configuration problem. Update QueryCraft; contact support if it persists. Your local data is kept.")
    }
    func failed(code: Int) -> String {
        text("暂时无法完成 iCloud 同步，请稍后重试。本机数据已保留（错误码 \(code)）。", "iCloud sync could not finish. Try again later. Your local data is kept (error \(code)).")
    }
    var unavailableInBuild: String {
        text("当前版本未启用 iCloud 同步。", "iCloud sync isn't available in this build.")
    }
    var requiresPurchase: String {
        text("iCloud 同步已暂停，请检查同步授权。本地功能和数据不受影响。", "iCloud sync is paused. Check your sync access. Local features and data are unaffected.")
    }
    var freeFeatures: String { text("全部本地功能永久免费。付费仅用于跨设备 iCloud 同步。", "All local features stay free. Payment only adds iCloud sync across devices.") }
    var syncAccess: String { text("同步授权", "Sync Access") }
    var licenseKey: String { text("授权码", "License Key") }
    var activateSync: String { text("激活同步", "Activate Sync") }
    var checkAccess: String { text("检查授权", "Check Access") }
    var accessActive: String { text("已解锁 iCloud 同步", "iCloud sync unlocked") }
    var restorePurchases: String { text("恢复购买", "Restore Purchases") }
    var reloadProducts: String { text("重新加载方案", "Reload Plans") }
    var purchaseUnavailable: String { text("暂时无法获取购买方案，请稍后重试。", "Purchase options are unavailable. Please try again later.") }
    var purchaseFailed: String { text("购买或验证未完成，请重试或恢复购买。本地功能不受影响。", "Purchase or verification could not complete. Retry or restore purchases. Local features are unaffected.") }
    var purchasePending: String { text("购买正在等待 Apple 确认，确认后会自动解锁同步。", "Your purchase is awaiting Apple's approval. Sync unlocks after approval.") }
    var noPurchases: String { text("当前 Apple 账户没有可恢复的同步购买。", "No sync purchases were found for this Apple Account.") }
    var manageSubscriptions: String { text("管理订阅", "Manage Subscriptions") }
    var subscriptionTerms: String { text("订阅自动续费，可在 Apple 账户中取消。永久方案一次买断，无需续费。", "Subscriptions renew automatically and can be cancelled in your Apple Account. The lifetime plan is a one-time purchase.") }
    var privacy: String { text("隐私政策", "Privacy Policy") }
    var terms: String { text("使用条款", "Terms of Use") }
    func planName(_ plan: CloudSyncPlan) -> String {
        switch plan {
        case .monthly: text("每月", "Monthly")
        case .halfYear: text("每半年", "Every 6 months")
        case .annual: text("每年", "Yearly")
        case .perpetual: text("永久 · 一次买断", "Lifetime · Pay once")
        }
    }
    var startTrialTitle: String { text("开始 30 天免费试用", "Start 30-Day Free Trial") }
    var trialNoCharge: String { text("不自动扣款，到期仅暂停同步", "No automatic charge. Only sync pauses when it ends.") }
    var trialTitle: String { text("免费试用", "Free Trial") }
    func trialRemaining(_ days: Int) -> String { text("剩余 \(days) 天", days == 1 ? "1 day left" : "\(days) days left") }
    func endsOn(_ date: Date) -> String {
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return text("\(day) 到期", "Ends \(day)")
    }
    var trialEndedShort: String { text("免费试用已结束", "Free trial ended") }
    var currentPlan: String { text("当前方案", "Current Plan") }
    var currentPeriodEnds: String { text("有效期至", "Active Until") }
    var lifetimeUnlocked: String { text("已永久解锁 iCloud 同步", "iCloud sync unlocked for life") }
    var websiteUnlocked: String { text("已通过官网授权解锁", "Unlocked with your website license") }
    func savings(_ percent: Int) -> String { text("省 \(percent)%", "Save \(percent)%") }
    var buyLicense: String { text("购买同步授权", "Buy a Sync License") }
    var websiteCheckoutOpened: String { text("已在浏览器打开付款页面。付款完成后回到 QueryCraft，会自动解锁当前 iCloud 账户。", "The payment page opened in your browser. Come back to QueryCraft after paying and this iCloud account unlocks automatically.") }
    var websiteCheckoutFailed: String { text("暂时无法打开付款页面，请稍后重试。本地功能不受影响。", "The payment page couldn't be opened. Try again later. Local features are unaffected.") }
    var websitePaymentPending: String { text("还没有确认同步权益。若已付款，请稍后点「重试」，无需重复付款。", "Sync access has not been confirmed yet. If you have paid, tap Retry in a moment. Do not pay again.") }
    func websitePlanSubtitle(_ plan: CloudSyncPlan) -> String {
        switch plan {
        case .monthly: text("有效期一个月，不自动续费", "One month, no automatic renewal")
        case .halfYear: text("有效期半年，不自动续费", "Six months, no automatic renewal")
        case .annual: text("有效期一年，不自动续费", "One year, no automatic renewal")
        case .perpetual: text("一次买断，永久同步", "Pay once, sync forever")
        }
    }
    var websitePlanTerms: String { text("通过支付宝一次性付款，绑定当前 iCloud 账户。到期不自动扣款，有效期内暂不支持续购或升级。", "Pay once with Alipay, linked to this iCloud account. No automatic renewal. Repurchasing or upgrading is unavailable during an active term.") }
    var retry: String { text("重试", "Retry") }
    var subscriptionShortTerms: String { text("订阅到期自动续费，可随时在 Apple 账户中取消。", "Subscriptions renew automatically. Cancel anytime in your Apple Account.") }
    func planTitle(_ plan: CloudSyncPlan) -> String {
        switch plan {
        case .monthly: text("月度", "Monthly")
        case .halfYear: text("半年", "6 Months")
        case .annual: text("年度", "Yearly")
        case .perpetual: text("永久", "Lifetime")
        }
    }
    func planSubtitle(_ plan: CloudSyncPlan) -> String {
        switch plan {
        case .monthly: text("按月自动续费", "Renews monthly")
        case .halfYear: text("每 6 个月自动续费", "Renews every 6 months")
        case .annual: text("按年自动续费", "Renews yearly")
        case .perpetual: text("一次买断，无需续费", "Pay once, no renewal")
        }
    }
    var localDataKept: String {
        text("关闭同步后，本机数据会保留，不会删除其他设备上的数据。",
             "Turning sync off keeps the data on this device and doesn't delete it from other devices.")
    }
}
