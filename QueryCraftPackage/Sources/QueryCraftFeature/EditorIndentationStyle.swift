enum EditorIndentationStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case spaces
    case tabs

    var id: Self { self }

}
