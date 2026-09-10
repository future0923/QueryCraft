import Testing
@testable import QueryCraftFeature

@Suite("Application Copy")
struct AppCopyTests {
    private let chinese = AppCopy(language: .simplifiedChinese)
    private let english = AppCopy(language: .english)

    @Test("Navigation and actions use the selected language")
    func navigationAndActions() {
        #expect(chinese.connections == "连接")
        #expect(english.connections == "Connections")
        #expect(chinese.objects == "对象")
        #expect(english.objects == "Objects")
        #expect(chinese.newQuery == "新建查询")
        #expect(english.newQuery == "New Query")
        #expect(chinese.retry == "重试")
        #expect(english.retry == "Retry")
    }

    @Test("Statuses and formatted data copy use the selected language")
    func statusesAndFormattedCopy() {
        #expect(chinese.ready == "就绪")
        #expect(english.ready == "Ready")
        #expect(chinese.rowCount(42) == "42 行")
        #expect(english.rowCount(42) == "42 rows")
        #expect(chinese.sortBy("created_at") == "按 created_at 排序")
        #expect(english.sortBy("created_at") == "Sort by created_at")
        let downloadDetail = english.driverDownloadDetail(
            receivedBytes: 1_000_000,
            totalBytes: 2_000_000,
            bytesPerSecond: 500_000
        )
        #expect(downloadDetail.contains("/"))
        #expect(downloadDetail.contains("·"))
        #expect(downloadDetail.contains("/s"))
    }

    @Test("Technical identifiers remain unchanged")
    func preservesTechnicalIdentifiers() {
        #expect(chinese.text("数据库 \(1)", "Database \(1)") == "数据库 1")
        #expect(english.text("数据库 \(1)", "Database \(1)") == "Database 1")
        #expect(chinese.sortBy("user_id") == "按 user_id 排序")
    }

    @Test("Workspace credential prompts use the selected language")
    func workspaceCredentialPrompt() {
        #expect(chinese.workspaceCredentialPromptTitle == "输入密码")
        #expect(english.workspaceCredentialPromptTitle == "Enter Password")
        #expect(chinese.password == "密码")
        #expect(english.password == "Password")
        #expect(chinese.connect == "连接")
        #expect(english.connect == "Connect")
        #expect(chinese.cancel == "取消")
        #expect(english.cancel == "Cancel")
        #expect(
            chinese.workspaceCredentialPromptMessage(
                profileName: "本地",
                username: "root",
                host: "127.0.0.1"
            ) == "请输入“本地”（root@127.0.0.1）的密码。密码仅用于本次工作区，不会保存。"
        )
        #expect(
            english.workspaceCredentialPromptMessage(
                profileName: "Local",
                username: "root",
                host: "127.0.0.1"
            ) == "Enter the password for \"Local\" (root@127.0.0.1). The password will be used for this workspace and will not be saved."
        )
    }
}
