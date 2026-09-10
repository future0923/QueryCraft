actor InMemorySavedQueryRepository: SavedQueryRepository {
    private var queries: [SavedQuery]

    init(queries: [SavedQuery] = []) {
        self.queries = queries
    }

    func fetchAll(
        connectionProfileID: ConnectionProfile.ID
    ) async throws -> [SavedQuery] {
        queries
            .filter {
                $0.connectionProfileID == connectionProfileID
            }
            .sorted(by: Self.areInDisplayOrder)
    }

    func fetch(id: SavedQuery.ID) async throws -> SavedQuery? {
        queries.first { $0.id == id }
    }

    func insert(_ query: SavedQuery) async throws {
        try validateNameScope(of: query)
        queries.append(query)
    }

    func update(_ query: SavedQuery) async throws {
        guard let index = queries.firstIndex(where: { $0.id == query.id })
        else {
            throw SavedQueryRepositoryError.queryNotFound
        }
        try validateNameScope(of: query)
        queries[index] = query
    }

    func delete(id: SavedQuery.ID) async throws {
        queries.removeAll { $0.id == id }
    }

    private func validateNameScope(of query: SavedQuery) throws {
        guard !queries.contains(where: {
            $0.id != query.id
                && $0.connectionProfileID == query.connectionProfileID
                && $0.defaultDatabase == query.defaultDatabase
                && $0.name == query.name
        }) else {
            throw SavedQueryRepositoryError.nameAlreadyExists
        }
    }

    private static func areInDisplayOrder(
        _ left: SavedQuery,
        _ right: SavedQuery
    ) -> Bool {
        switch (left.defaultDatabase, right.defaultDatabase) {
        case (nil, nil):
            break
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (leftDatabase?, rightDatabase?):
            let order = leftDatabase.localizedStandardCompare(rightDatabase)
            if order != .orderedSame {
                return order == .orderedAscending
            }
        }

        let nameOrder = left.name.localizedStandardCompare(right.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id.uuidString < right.id.uuidString
    }
}
