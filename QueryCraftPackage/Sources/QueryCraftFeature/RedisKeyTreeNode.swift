import Foundation

struct RedisKeyTreeNode: Equatable, Identifiable, Sendable {
    enum Content: Equatable, Sendable {
        case prefix(path: String)
        case key(RedisKeyReference)
    }

    let id: String
    let title: String
    let content: Content
    let children: [RedisKeyTreeNode]
    let keyCount: Int

    var outlineChildren: [RedisKeyTreeNode]? {
        children.isEmpty ? nil : children
    }

    var reference: RedisKeyReference? {
        guard case let .key(reference) = content else { return nil }
        return reference
    }

    func isSelected(_ selection: RedisKeyReference?) -> Bool {
        guard let reference else { return false }
        return reference == selection
    }
}

actor RedisKeyTreeBuilder {
    func build(
        keys: [RedisKeyReference],
        matching searchText: String
    ) -> [RedisKeyTreeNode] {
        build(
            keys: keys,
            matching: RedisKeySearchRequest(
                text: searchText,
                mode: .contains
            )
        )
    }

    func build(
        keys: [RedisKeyReference],
        matching search: RedisKeySearchRequest
    ) -> [RedisKeyTreeNode] {
        let filteredKeys = keys.filter(search.matchesLoadedKey)
        var root = RedisKeyTreeBranch()
        for (offset, key) in filteredKeys.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return [] }
            root.insert(key)
        }
        return root.nodes(path: "", databaseIndex: keys.first?.databaseIndex ?? 0)
    }
}

extension Array where Element == RedisKeyTreeNode {
    var keyReferences: [RedisKeyReference] {
        flatMap { node in
            if let reference = node.reference { return [reference] }
            return node.children.keyReferences
        }
    }

    func contains(reference: RedisKeyReference) -> Bool {
        contains { node in
            node.reference == reference
                || node.children.contains(reference: reference)
        }
    }
}

private extension RedisKeySearchRequest {
    func matchesLoadedKey(_ reference: RedisKeyReference) -> Bool {
        guard !text.isEmpty else { return true }
        switch mode {
        case .contains:
            // Redis glob patterns need the server to determine a match. Keeping
            // them out of the interim tree avoids briefly showing a false hit.
            guard !text.contains(where: "*?[]\\".contains) else { return false }
            return reference.name.contains(text)
        case .prefix:
            return reference.name.hasPrefix(text)
        case .exact:
            return reference.name == text
        }
    }
}

private struct RedisKeyTreeBranch {
    var branches: [String: RedisKeyTreeBranch] = [:]
    var keys: [RedisKeyReference] = []

    mutating func insert(_ key: RedisKeyReference) {
        let components = key.name.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count > 1 else {
            keys.append(key)
            return
        }
        insert(key, components: Array(components.dropLast()))
    }

    private mutating func insert(
        _ key: RedisKeyReference,
        components: [String]
    ) {
        guard let component = components.first else {
            keys.append(key)
            return
        }
        var branch = branches.removeValue(forKey: component)
            ?? RedisKeyTreeBranch()
        branch.insert(key, components: Array(components.dropFirst()))
        branches[component] = branch
    }

    func nodes(path: String, databaseIndex: Int) -> [RedisKeyTreeNode] {
        let branchNodes = branches.keys.sorted(by: localizedAscending).compactMap {
            component -> RedisKeyTreeNode? in
            guard let branch = branches[component] else { return nil }
            let childPath = path.isEmpty ? component : "\(path):\(component)"
            let children = branch.nodes(
                path: childPath,
                databaseIndex: databaseIndex
            )
            return RedisKeyTreeNode(
                id: "redis-prefix:\(databaseIndex):\(childPath)",
                title: component.isEmpty ? ":" : component,
                content: .prefix(path: childPath),
                children: children,
                keyCount: children.reduce(0) { $0 + $1.keyCount }
            )
        }
        let keyNodes = keys.sorted { localizedAscending($0.name, $1.name) }.map {
            key in
            RedisKeyTreeNode(
                id: "redis-key:\(key.id)",
                title: key.name,
                content: .key(key),
                children: [],
                keyCount: 1
            )
        }
        return branchNodes + keyNodes
    }

    private func localizedAscending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
