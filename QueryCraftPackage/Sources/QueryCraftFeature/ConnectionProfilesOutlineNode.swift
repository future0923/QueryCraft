import Foundation

@MainActor
final class ConnectionProfilesOutlineNode: NSObject {
    enum Kind {
        case ungrouped
        case group(ConnectionGroup)
        case profile(ConnectionProfile)
    }

    let id: String
    var kind: Kind

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}
