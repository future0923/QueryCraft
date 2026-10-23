import Foundation

/// Same matcher, tiers, scores and stable tie order as WorkspaceDatabaseItems on Mac.
enum MobileCatalogSearch {
    static func objects(_ objects: [MobileDatabaseObject], matching search: String) -> [MobileDatabaseObject] {
        CompletionLabelMatcher.matching(objects, query: search, label: \.name)
    }
}
