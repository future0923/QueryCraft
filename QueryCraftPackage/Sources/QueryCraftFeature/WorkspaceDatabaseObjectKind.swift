public enum WorkspaceDatabaseObjectKind:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case table
    case view
    case elasticsearchIndex
    case elasticsearchAlias
    case elasticsearchDataStream
    case milvusCollection

    var title: String {
        switch self {
        case .table:
            AppCopy.current.text("表", "Tables")
        case .view:
            AppCopy.current.text("视图", "Views")
        case .elasticsearchIndex:
            AppCopy.current.text("索引", "Indices")
        case .elasticsearchAlias:
            "Aliases"
        case .elasticsearchDataStream:
            AppCopy.current.text("数据流", "Data Streams")
        case .milvusCollection:
            AppCopy.current.text("集合", "Collections")
        }
    }

    var systemImage: String {
        switch self {
        case .table:
            "tablecells"
        case .view:
            "eye"
        case .elasticsearchIndex:
            "square.stack.3d.up"
        case .elasticsearchAlias:
            "arrow.triangle.branch"
        case .elasticsearchDataStream:
            "waveform.path.ecg"
        case .milvusCollection:
            "square.stack.3d.up"
        }
    }
}
