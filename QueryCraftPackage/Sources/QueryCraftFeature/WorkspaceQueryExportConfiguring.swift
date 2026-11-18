/// Optional capability. Older drivers remain usable for queries, but cannot claim bounded exports.
public protocol WorkspaceQueryExportConfiguring: Sendable {
    func configureQueryExport(maximumRowBytes: Int) async throws
}
