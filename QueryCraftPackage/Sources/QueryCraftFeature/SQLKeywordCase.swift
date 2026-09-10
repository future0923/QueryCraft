enum SQLKeywordCase: String, CaseIterable, Identifiable, Sendable {
    case uppercase
    case lowercase
    case preserve

    var id: Self { self }

}
