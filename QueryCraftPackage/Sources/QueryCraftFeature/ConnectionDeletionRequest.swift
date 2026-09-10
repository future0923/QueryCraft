import Foundation

struct ConnectionDeletionRequest: Equatable, Identifiable, Sendable {
    let target: ConnectionDeletionTarget
    let profileIDs: [ConnectionProfile.ID]
    let impact: ConnectionDeletionImpact

    var id: UUID {
        switch target {
        case .profile(let id, _), .group(let id, _):
            id
        }
    }

    var name: String {
        switch target {
        case .profile(_, let name), .group(_, let name):
            name
        }
    }

    var isGroup: Bool {
        if case .group = target {
            true
        } else {
            false
        }
    }

    var confirmationTitle: String {
        isGroup
            ? AppCopy.current.text("删除连接分组？", "Delete Connection Group?")
            : AppCopy.current.text("删除连接配置？", "Delete Connection Profile?")
    }

    var confirmationMessage: String {
        let englishSubject = isGroup
            ? "The group \"\(name)\" and its profiles"
            : "The profile \"\(name)\""
        let chineseSubject = isGroup
            ? "连接分组“\(name)”及其中的连接配置"
            : "连接配置“\(name)”"
        return AppCopy.current.text(
            """
            \(chineseSubject)将被永久删除。

            连接配置：\(impact.connectionProfileCount)
            已保存查询：\(impact.savedQueryCount)
            可恢复草稿：\(impact.recoverableDraftCount)
            工作区恢复记录：\(impact.workspaceRestorationCount)
            钥匙串凭据：\(impact.storedCredentialCount)
            """,
            """
            \(englishSubject) will be permanently deleted.

            Connection Profiles: \(impact.connectionProfileCount)
            Saved Queries: \(impact.savedQueryCount)
            Recoverable Drafts: \(impact.recoverableDraftCount)
            Workspace Restorations: \(impact.workspaceRestorationCount)
            Keychain Credentials: \(impact.storedCredentialCount)
            """
        )
    }
}
