import Foundation

/// Review one database object at a time; column/index choices remain in the
/// differences step and are projected together into that object's SQL plan.
struct SchemaComparisonReviewGroup: Identifiable {
    let id: String
    let differences: [SchemaComparisonDifference]
    var title: String { differences[0].table }
    var ids: Set<String> { Set(differences.map(\.id)) }
    var status: SchemaComparisonDifference.Status {
        if let atomic = differences.first(where: { ["table", "view", "function", "sequence", "rule", "owner"].contains($0.object) }),
           atomic.status == .added || atomic.status == .targetOnly { return atomic.status }
        return .modified
    }
    var symbol: String {
        let first = differences[0]
        return first.object == "function" || first.object == "view" ? first.kindSymbol : "tablecells"
    }
    var routineKind: String? { differences[0].object == "function" ? differences[0].kindTitle : nil }
    static func groups(_ differences: [SchemaComparisonDifference]) -> [Self] {
        Dictionary(grouping: differences, by: \.groupKey).map { Self(id: $0.key, differences: $0.value) }
            .sorted {
                func order(_ status: SchemaComparisonDifference.Status) -> Int {
                    switch status { case .added: 0; case .modified: 1; case .targetOnly: 2; default: 3 }
                }
                let l = order($0.status), r = order($1.status)
                if l != r { return l < r }
                if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return $0.id < $1.id
            }
    }
}
