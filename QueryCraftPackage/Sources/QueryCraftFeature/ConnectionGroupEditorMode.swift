import Foundation

enum ConnectionGroupEditorMode: Identifiable {
    case create
    case rename(ConnectionGroup)

    var id: UUID {
        switch self {
        case .create:
            UUID.zero
        case .rename(let group):
            group.id
        }
    }
}

private extension UUID {
    static let zero = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    ))
}
