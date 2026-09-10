enum WorkspaceDatabaseObjectDetailTab: String, CaseIterable, Hashable, Identifiable {
    case data = "Data"
    case structure = "Structure"
    case indexes = "Indexes"
    case options = "Options"
    case ddl = "DDL"

    var id: Self { self }

    var title: String {
        return switch self {
        case .data:
            AppCopy.current.text("数据", "Data")
        case .structure:
            AppCopy.current.text("结构", "Structure")
        case .indexes:
            AppCopy.current.text("索引", "Indexes")
        case .options:
            AppCopy.current.text("选项", "Options")
        case .ddl:
            "DDL"
        }
    }

    var openTitle: String {
        AppCopy.current.text("打开\(title)", "Open \(title)")
    }

    func title(for kind: WorkspaceDatabaseObjectKind) -> String {
        guard kind == .elasticsearchIndex
                || kind == .elasticsearchAlias
                || kind == .elasticsearchDataStream
        else { return title }
        return switch self {
        case .data:
            AppCopy.current.text("文档", "Documents")
        case .structure:
            "Mapping"
        case .indexes, .options, .ddl:
            title
        }
    }

    func openTitle(for kind: WorkspaceDatabaseObjectKind) -> String {
        let contextualTitle = title(for: kind)
        return AppCopy.current.text(
            "打开\(contextualTitle)",
            "Open \(contextualTitle)"
        )
    }

    var shortcutCharacter: Character {
        switch self {
        case .data:
            "1"
        case .structure:
            "2"
        case .indexes:
            "3"
        case .options:
            "4"
        case .ddl:
            "5"
        }
    }

    var shortcutKeyCode: UInt16 {
        switch self {
        case .data:
            18
        case .structure:
            19
        case .indexes:
            20
        case .options:
            21
        case .ddl:
            23
        }
    }

    static func available(for kind: WorkspaceDatabaseObjectKind) -> [Self] {
        switch kind {
        case .table:
            [.data, .structure, .indexes, .options, .ddl]
        case .view:
            [.data, .structure, .ddl]
        case .elasticsearchIndex,
             .elasticsearchAlias,
             .elasticsearchDataStream:
            [.data, .structure]
        }
    }
}

struct WorkspaceDatabaseObjectDetailTabShortcut: Equatable {
    let character: Character
    let keyCode: UInt16

    static func commandNumber(at index: Int) -> Self? {
        let shortcuts = [
            Self(character: "1", keyCode: 18),
            Self(character: "2", keyCode: 19),
            Self(character: "3", keyCode: 20),
            Self(character: "4", keyCode: 21),
            Self(character: "5", keyCode: 23),
        ]
        guard shortcuts.indices.contains(index) else { return nil }
        return shortcuts[index]
    }
}
