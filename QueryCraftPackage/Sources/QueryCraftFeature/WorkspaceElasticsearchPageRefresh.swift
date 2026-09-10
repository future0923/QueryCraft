enum WorkspaceElasticsearchPageRefresh {
    static func offset(requested: Int, limit: Int, totalCount: Int?) -> Int {
        guard requested > 0, limit > 0, let totalCount, totalCount > 0 else {
            return 0
        }
        let lastPageOffset = ((totalCount - 1) / limit) * limit
        let offset = requested < totalCount ? requested : lastPageOffset
        // A fresh PIT has no search_after cursors; never reuse a cursor from the old snapshot.
        let directWindow = 10_000
        guard offset <= directWindow - min(limit, directWindow) else { return 0 }
        return offset
    }
}
