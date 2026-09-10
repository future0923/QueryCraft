import Foundation

enum ConnectionDeletionTarget: Equatable, Sendable {
    case profile(id: ConnectionProfile.ID, name: String)
    case group(id: ConnectionGroup.ID, name: String)
}
