import Foundation

enum SavedQueryRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case nameAlreadyExists
    case queryNotFound

    var errorDescription: String? {
        switch self {
        case .nameAlreadyExists:
            AppCopy.current.text(
                "该位置已存在同名的已保存查询。",
                "A Saved Query with this name already exists in that location."
            )
        case .queryNotFound:
            AppCopy.current.text(
                "已保存查询已不存在。",
                "The Saved Query no longer exists."
            )
        }
    }
}
