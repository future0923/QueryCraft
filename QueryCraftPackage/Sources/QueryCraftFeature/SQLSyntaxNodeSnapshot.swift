import Foundation

struct SQLSyntaxNodeSnapshot: Equatable, Sendable {
    let type: String
    let range: SQLSourceRange
    let children: [SQLSyntaxNodeSnapshot]

    var isLeaf: Bool {
        children.isEmpty
    }

    func descendants(named type: String) -> [SQLSyntaxNodeSnapshot] {
        var matches = self.type == type ? [self] : []
        for child in children {
            matches.append(contentsOf: child.descendants(named: type))
        }
        return matches
    }
}
