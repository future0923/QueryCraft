import Foundation

enum WelcomeManagementError: LocalizedError, Equatable {
    case emptyGroupName
    case duplicateGroupName(String)
    case missingGroup
    case missingProfile
    case deletionContentsChanged
    case profileOwnsOpenWorkspace(String)
    case groupOwnsOpenWorkspace(groupName: String, profileName: String)

    var errorDescription: String? {
        switch self {
        case .emptyGroupName:
            AppCopy.current.text("请输入分组名称。", "Enter a group name.")
        case .duplicateGroupName(let name):
            AppCopy.current.text(
                "名为“\(name)”的连接分组已存在。",
                "A connection group named \"\(name)\" already exists."
            )
        case .missingGroup:
            AppCopy.current.text(
                "该连接分组已不存在。",
                "The connection group is no longer available."
            )
        case .missingProfile:
            AppCopy.current.text(
                "该连接配置已不存在。",
                "The connection profile is no longer available."
            )
        case .deletionContentsChanged:
            AppCopy.current.text(
                "受影响的连接数据已发生变化，请确认最新数量后再删除。",
                """
                The affected connection data changed. Review the updated counts \
                before deleting.
                """
            )
        case .profileOwnsOpenWorkspace(let name):
            AppCopy.current.text(
                "请先关闭所有使用“\(name)”的工作区，再删除该连接。",
                "Close every workspace using \"\(name)\" before deleting it."
            )
        case .groupOwnsOpenWorkspace(let groupName, let profileName):
            AppCopy.current.text(
                "请先关闭所有使用“\(profileName)”的工作区，再删除“\(groupName)”。",
                """
                Close every workspace using "\(profileName)" before deleting \
                "\(groupName)".
                """
            )
        }
    }
}
