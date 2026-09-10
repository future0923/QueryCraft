import AppKit

extension RedisKeyType {
    var sidebarBadgeText: String? {
        switch self {
        case .string: "str"
        case .list: "list"
        case .set: "set"
        case .sortedSet: "zset"
        case .hash: "hash"
        case .stream: "stream"
        case .module: "mod"
        case .none, .unknown: nil
        }
    }

    var badgeTintColor: NSColor {
        switch self {
        case .string: .systemBlue
        case .list: .systemIndigo
        case .set: .systemGreen
        case .sortedSet: .systemPurple
        case .hash: .systemOrange
        case .stream: .systemRed
        case .module: .systemTeal
        case .none, .unknown: .secondaryLabelColor
        }
    }
}
