import Foundation

public enum DatabaseProduct: String, CaseIterable, Codable, Identifiable, Sendable {
    case mysql
    case postgresql
    case apacheDoris
    case selectDB
    case redis
    case elasticsearch
    case kafka

    public var id: String { rawValue }

    public var databaseType: DatabaseType {
        switch self {
        case .mysql:
            .mysql
        case .postgresql:
            .postgresql
        case .apacheDoris, .selectDB:
            .doris
        case .redis:
            .redis
        case .elasticsearch:
            .elasticsearch
        case .kafka:
            .kafka
        }
    }

    public static func defaultProduct(for databaseType: DatabaseType) -> Self {
        switch databaseType {
        case .mysql:
            .mysql
        case .postgresql:
            .postgresql
        case .doris:
            .apacheDoris
        case .redis:
            .redis
        case .elasticsearch:
            .elasticsearch
        case .kafka:
            .kafka
        }
    }
}
