import Foundation

@MainActor
final class RedisKeyOutlineItem: NSObject {
    let node: RedisKeyTreeNode
    var children: [RedisKeyOutlineItem]?

    init(node: RedisKeyTreeNode) {
        self.node = node
    }
}
