import Foundation

enum WorkspaceSavedQueryError: Error, Equatable, LocalizedError, Sendable {
    case documentNotFound
    case missingName
    case operationInProgress
    case queryNotFound
    case saveInProgress

    var errorDescription: String? {
        switch self {
        case .documentNotFound:
            AppCopy.current.text(
                "查询文档已不再打开。",
                "The Query Document is no longer open."
            )
        case .missingName:
            AppCopy.current.text(
                "请输入已保存查询的名称。",
                "Enter a name for this Saved Query."
            )
        case .operationInProgress:
            AppCopy.current.text(
                "正在更改此已保存查询。",
                "This Saved Query is already being changed."
            )
        case .queryNotFound:
            AppCopy.current.text(
                "该已保存查询已不存在。",
                "The Saved Query is no longer available."
            )
        case .saveInProgress:
            AppCopy.current.text(
                "正在保存此查询文档。",
                "This Query Document is already being saved."
            )
        }
    }
}
