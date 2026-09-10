import AppKit

enum RedisCollectionGridKind: Equatable {
    case list
    case hash
    case hashWithFieldExpiration
    case set
    case sortedSet

    var columnTitles: [String] {
        switch self {
        case .list:
            [
                AppCopy.current.text("索引", "Index"),
                AppCopy.current.text("值", "Value"),
            ]
        case .hash:
            [
                AppCopy.current.text("字段", "Field"),
                AppCopy.current.text("值", "Value"),
            ]
        case .hashWithFieldExpiration:
            [
                AppCopy.current.text("字段", "Field"),
                AppCopy.current.text("值", "Value"),
                "TTL (ms)",
            ]
        case .set:
            [AppCopy.current.text("成员", "Member")]
        case .sortedSet:
            [
                AppCopy.current.text("成员", "Member"),
                AppCopy.current.text("分数", "Score"),
            ]
        }
    }

    var cells: [RedisKeyEditableCell] {
        switch self {
        case .set:
            [.firstValue]
        case .list, .hash, .sortedSet:
            [.firstValue, .secondValue]
        case .hashWithFieldExpiration:
            [.firstValue, .secondValue, .thirdValue]
        }
    }

    var preferredColumnWidths: [CGFloat] {
        switch self {
        case .list:
            [100, 420]
        case .hash:
            [180, 280]
        case .hashWithFieldExpiration:
            [180, 280, 120]
        case .set:
            [420]
        case .sortedSet:
            [300, 140]
        }
    }

    var deletedActionTitle: String {
        switch self {
        case .hash, .hashWithFieldExpiration:
            AppCopy.current.text("撤销删除字段", "Undo Delete Field")
        case .list:
            AppCopy.current.text("撤销删除元素", "Undo Delete Element")
        case .set, .sortedSet:
            AppCopy.current.text("撤销删除成员", "Undo Delete Member")
        }
    }

    var deleteActionTitle: String {
        switch self {
        case .hash, .hashWithFieldExpiration:
            AppCopy.current.text("删除字段", "Delete Field")
        case .list:
            AppCopy.current.text("删除元素", "Delete Element")
        case .set, .sortedSet:
            AppCopy.current.text("删除成员", "Delete Member")
        }
    }
}
