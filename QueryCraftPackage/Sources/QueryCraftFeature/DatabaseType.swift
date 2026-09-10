import Foundation

public enum DatabaseType: String, CaseIterable, Codable, Identifiable, Sendable {
    case mysql
    case postgresql
    case doris
    case redis
    case elasticsearch

    public var id: String { rawValue }
}
