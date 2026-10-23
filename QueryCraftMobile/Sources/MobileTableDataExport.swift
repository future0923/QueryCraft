import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

extension MobileDataExportSnapshot {
    static func table(_ captured: MobileTableSnapshot, configuration: MariaDBTransportConfiguration,
                      service: any MobileMySQLServicing) -> Self {
        let data = MobileGridData(preview: captured.preview)
        let expected = captured.preview.result.workspaceColumns
        return .init(data: data, name: captured.object.name, scopeDescription: "当前表页",
            tableIdentifierParts: [captured.object.database, captured.object.name],
            allRowsProvider: .init(estimatedRowCount: nil, makeSource: {
                WorkspacePagedDataExportRowSource(pageSize: 200, expectedColumns: expected, loadPage: { offset, limit in
                    // Reuse the real table predicate/ordering/typed transport, not a second export query builder.
                    let page = try await service.page(configuration: configuration, object: captured.object,
                        columns: captured.columns, offset: offset, size: limit, sortColumn: captured.sortColumn,
                        ascending: captured.ascending, filter: captured.filter)
                    guard !page.preview.isTruncated else { throw MobileQueryError.resultTooLarge }
                    let grid = MobileGridData(preview: page.preview)
                    guard grid.rows.count <= limit,
                          grid.rows.allSatisfy({ $0.count == grid.columns.count }) else {
                        throw WorkspaceDataExportError.missingRow
                    }
                    let rows = grid.rows.indices.map { index in
                        WorkspaceDatabaseDataRow(id: offset + index, values: grid.columns.indices.map {
                            grid.cell(row: index, column: $0)
                        })
                    }
                    return .init(columns: page.preview.result.workspaceColumns, rows: rows, hasNextPage: page.hasNextPage)
                })
            }), hasBinaryColumns: captured.columns.contains { column in
                let type = column.type.lowercased().split(separator: "(").first.map(String.init) ?? ""
                return ["binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "bit", "geometry"].contains(type)
            })
    }
}
