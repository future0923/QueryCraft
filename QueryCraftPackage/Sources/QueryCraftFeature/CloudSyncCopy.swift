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
        isChinese ? chinese : english
    }

    var title: String { text("iCloud 同步", "iCloud Sync") }
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
        text("iCloud 储存空间已满，暂时无法上传。", "iCloud storage is full, so changes can't be uploaded.")
    }
    var networkUnavailable: String {
        text("网络不可用，恢复后会自动继续同步。", "The network is unavailable. Sync resumes automatically.")
    }
    var unavailableInBuild: String {
        text("当前版本未启用 iCloud 同步。", "iCloud sync isn't available in this build.")
    }
    var requiresPurchase: String {
        text("iCloud 同步属于付费功能，可免费试用 30 天。", "iCloud sync is a paid feature with a 30-day free trial.")
    }
    var localDataKept: String {
        text("关闭同步后，本机数据会保留，不会删除其他设备上的数据。",
             "Turning sync off keeps the data on this device and doesn't delete it from other devices.")
    }
}
