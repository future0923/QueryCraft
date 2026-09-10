enum QueryResultRowLimit: String, CaseIterable, Codable, Identifiable, Sendable {
    case unlimited
    case rows100
    case rows500
    case rows1_000
    case rows5_000
    case rows10_000
    case rows50_000
    case rows100_000
    case rows500_000

    var id: Self { self }

    var maximumRows: Int? {
        switch self {
        case .unlimited:
            nil
        case .rows100:
            100
        case .rows500:
            500
        case .rows1_000:
            1_000
        case .rows5_000:
            5_000
        case .rows10_000:
            10_000
        case .rows50_000:
            50_000
        case .rows100_000:
            100_000
        case .rows500_000:
            500_000
        }
    }
}
