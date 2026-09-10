import Foundation

enum QueryTimeoutOption: String, CaseIterable, Identifiable, Sendable {
    case unlimited
    case seconds30
    case seconds60
    case seconds120

    var id: Self { self }

    var duration: Duration? {
        switch self {
        case .unlimited:
            nil
        case .seconds30:
            .seconds(30)
        case .seconds60:
            .seconds(60)
        case .seconds120:
            .seconds(120)
        }
    }
}
