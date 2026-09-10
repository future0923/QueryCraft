import Foundation

struct ConnectionDragItem: Codable {
    enum Kind: String, Codable {
        case group
        case profile
    }

    let kind: Kind
    let id: UUID
}
