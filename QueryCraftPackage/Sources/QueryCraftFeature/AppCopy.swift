import Foundation

public struct AppCopy: Sendable {
    private let isChinese: Bool

    init(language: ApplicationLanguage) {
        isChinese = language.usesSimplifiedChinese
    }

    public static var current: AppCopy {
        AppCopy(language: .activeInterfaceLanguage)
    }

    public func text(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }

    var connections: String {
        text("连接", "Connections")
    }

    var viewFullCellContent: String {
        text("查看完整内容…", "View Full Content...")
    }

    var newQuery: String {
        text("新建查询", "New Query")
    }

    var objects: String {
        text("对象", "Objects")
    }

    var retry: String {
        text("重试", "Retry")
    }

    var workspaceCredentialPromptTitle: String {
        text("输入密码", "Enter Password")
    }

    var password: String {
        text("密码", "Password")
    }

    var connect: String {
        text("连接", "Connect")
    }

    var cancel: String {
        text("取消", "Cancel")
    }

    var ready: String {
        text("就绪", "Ready")
    }

    func rowCount(_ count: Int) -> String {
        text("\(count) 行", "\(count) rows")
    }

    func sortBy(_ columnName: String) -> String {
        text("按 \(columnName) 排序", "Sort by \(columnName)")
    }

    func driverDownloadDetail(
        receivedBytes: Int64,
        totalBytes: Int64?,
        bytesPerSecond: Double?
    ) -> String {
        var detail = Self.formattedByteCount(receivedBytes)
        if let totalBytes {
            detail += " / \(Self.formattedByteCount(totalBytes))"
        }
        if let bytesPerSecond {
            let speed = Int64(min(bytesPerSecond, Double(Int64.max)))
            detail += " · \(Self.formattedByteCount(speed))/s"
        }
        return detail
    }

    func workspaceCredentialPromptMessage(
        profileName: String,
        username: String,
        host: String
    ) -> String {
        text(
            "请输入“\(profileName)”（\(username)@\(host)）的密码。密码仅用于本次工作区，不会保存。",
            "Enter the password for \"\(profileName)\" (\(username)@\(host)). The password will be used for this workspace and will not be saved."
        )
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(byteCount, 0),
            countStyle: .file
        )
    }
}
