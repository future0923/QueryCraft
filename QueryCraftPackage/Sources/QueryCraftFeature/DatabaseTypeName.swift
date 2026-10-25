extension DatabaseType {
    public var title: String {
        switch self {
        case .mysql: "MySQL"
        case .postgresql: "PostgreSQL"
        case .doris: "Doris"
        case .redis: "Redis"
        case .elasticsearch: "Elasticsearch"
        case .kafka: "Kafka"
        }
    }
}
