import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceSQLObjectOverviewModel {
    private(set) var entries: [WorkspaceSQLObjectOverviewEntry] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var didCompleteRefresh = false
    private var database: String?
    private var requestID = UUID()

    func clearRefreshCompletion() {
        didCompleteRefresh = false
    }

    func load(database: String, fetch: (String) async throws -> [WorkspaceSQLObjectOverviewEntry]) async {
        let id = UUID()
        requestID = id
        if self.database != database {
            entries = []
            hasLoaded = false
        }
        self.database = database
        isLoading = true
        error = nil
        didCompleteRefresh = false
        defer { if requestID == id { isLoading = false } }
        do {
            let result = try await fetch(database)
            try Task.checkCancellation()
            guard requestID == id else { return }
            entries = result
            hasLoaded = true
            didCompleteRefresh = true
        } catch is CancellationError {
            // Keep the previous successful content when a refresh is cancelled.
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

enum WorkspaceSQLObjectOverviewKind: String, CaseIterable {
    case table, view, query

    var title: String {
        switch self {
        case .table: AppCopy.current.text("表", "Table")
        case .view: AppCopy.current.text("视图", "View")
        case .query: AppCopy.current.text("查询", "Query")
        }
    }

    var chineseTitle: String {
        switch self {
        case .table: "表"
        case .view: "视图"
        case .query: "查询"
        }
    }

    var systemImage: String {
        switch self {
        case .table: "tablecells"
        case .view: "eye"
        case .query: "doc.text"
        }
    }
}

struct WorkspaceSQLObjectOverviewRow: Identifiable {
    private enum Source {
        case object(WorkspaceSQLObjectOverviewEntry)
        case query(SavedQuery)
    }
    private let source: Source

    init(entry: WorkspaceSQLObjectOverviewEntry) { source = .object(entry) }
    init(query: SavedQuery) { source = .query(query) }

    var entry: WorkspaceSQLObjectOverviewEntry? {
        if case let .object(entry) = source { return entry }
        return nil
    }
    var savedQuery: SavedQuery? {
        if case let .query(query) = source { return query }
        return nil
    }
    var id: String {
        switch source {
        case let .object(entry): entry.id
        case let .query(query): "query:\(query.id)"
        }
    }
    var name: String {
        switch source {
        case let .object(entry): entry.object.name
        case let .query(query): query.name
        }
    }
    var kind: WorkspaceSQLObjectOverviewKind {
        if let entry { return entry.object.kind == .view ? .view : .table }
        return .query
    }
    var type: String { kind.title }
    var comment: String { entry?.comment ?? "" }
    var engine: String { entry?.engine ?? "" }
    var collation: String { entry?.collation ?? "" }
    var rowCount: Int64 { entry?.estimatedRowCount ?? -1 }
    var storageSize: Int64 { entry?.storageByteCount ?? -1 }

    static func filtered(_ entries: [WorkspaceSQLObjectOverviewEntry], search: String,
                         schema: String?, kind: WorkspaceSQLObjectOverviewKind?,
                         savedQueries: [SavedQuery] = [], database: String? = nil) -> [Self] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let objects = entries.filter { schema == nil || $0.object.schemaName == schema }
            .map { Self(entry: $0) }
        let queries = savedQueries.filter {
            $0.defaultDatabase == nil || $0.defaultDatabase == database
        }.map { Self(query: $0) }
        return (objects + queries).filter { row in
            (kind == nil || row.kind == kind)
                && (search.isEmpty || [row.name, row.comment, row.engine, row.collation,
                    row.kind.rawValue, row.kind.chineseTitle, row.savedQuery?.sql ?? ""
                ].contains { CompletionLabelMatcher.match(label: $0, query: search) != nil })
        }
    }
}
