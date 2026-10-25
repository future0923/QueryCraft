enum SQLKeywordCase: String, CaseIterable, Identifiable, Codable, Sendable {
    case uppercase
    case lowercase
    case preserve

    var id: Self { self }

}
