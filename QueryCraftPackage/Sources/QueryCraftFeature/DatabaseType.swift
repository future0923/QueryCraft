import Foundation

public enum DatabaseType: String, CaseIterable, Codable, Identifiable, Sendable {
    case mysql
    case postgresql
    case doris
    case redis
    case elasticsearch
    case kafka

    public var id: String { rawValue }
}

// The object overview applies only to relational SQL drivers.
extension DatabaseType {
    var supportsSQLObjectOverview: Bool {
        switch self {
        case .mysql, .postgresql, .doris: true
        case .redis, .elasticsearch, .kafka: false
        }
    }
}
