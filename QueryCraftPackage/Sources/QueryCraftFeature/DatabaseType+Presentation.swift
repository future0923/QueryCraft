extension DatabaseType {
    var title: String {
        switch self {
        case .mysql: "MySQL"
        case .postgresql: "PostgreSQL"
        case .doris: "Doris"
        case .redis: "Redis"
        case .elasticsearch: "Elasticsearch"
        }
    }

    var defaultPort: Int {
        switch self {
        case .mysql: 3_306
        case .postgresql: 5_432
        case .doris: 9_030
        case .redis: 6_379
        case .elasticsearch: 9_200
        }
    }

    var defaultUsername: String {
        switch self {
        case .mysql: "root"
        case .postgresql: "postgres"
        case .doris: "root"
        case .redis: ""
        case .elasticsearch: "elastic"
        }
    }

    var brandAssetName: String {
        brandPresentation.assetName
    }

    var brandPresentation: DatabaseBrandPresentation {
        switch self {
        case .mysql: .mysql
        case .postgresql: .postgreSQL
        case .doris: .apacheDoris
        case .redis: .redis
        case .elasticsearch: .elasticsearch
        }
    }

    var tagline: String {
        switch self {
        case .mysql:
            AppCopy.current.text(
                "流行的开源关系型数据库",
                "Popular open-source relational database"
            )
        case .postgresql:
            AppCopy.current.text(
                "高级对象关系型数据库",
                "Advanced object-relational database"
            )
        case .doris:
            AppCopy.current.text(
                "面向实时分析的分布式数据库",
                "Distributed database for real-time analytics"
            )
        case .redis:
            AppCopy.current.text(
                "内存数据存储与缓存",
                "In-memory data store and cache"
            )
        case .elasticsearch:
            AppCopy.current.text(
                "分布式搜索与分析引擎",
                "Distributed search and analytics engine"
            )
        }
    }
}

extension DatabaseProduct {
    var title: String {
        switch self {
        case .mysql: "MySQL"
        case .postgresql: "PostgreSQL"
        case .apacheDoris: "Apache Doris"
        case .selectDB: "SelectDB"
        case .redis: "Redis"
        case .elasticsearch: "Elasticsearch"
        }
    }

    var defaultPort: Int { databaseType.defaultPort }
    var defaultUsername: String { databaseType.defaultUsername }

    var brandAssetName: String {
        brandPresentation.assetName
    }

    var brandPresentation: DatabaseBrandPresentation {
        switch self {
        case .mysql: .mysql
        case .postgresql: .postgreSQL
        case .apacheDoris: .apacheDoris
        case .selectDB: .selectDB
        case .redis: .redis
        case .elasticsearch: .elasticsearch
        }
    }

    var tagline: String {
        switch self {
        case .mysql:
            AppCopy.current.text(
                "流行的开源关系型数据库",
                "Popular open-source relational database"
            )
        case .postgresql:
            AppCopy.current.text(
                "高级对象关系型数据库",
                "Advanced object-relational database"
            )
        case .apacheDoris:
            AppCopy.current.text(
                "开源实时分析型数据库",
                "Open-source database for real-time analytics"
            )
        case .selectDB:
            AppCopy.current.text(
                "基于 Apache Doris 的云原生数据仓库",
                "Cloud-native data warehouse powered by Apache Doris"
            )
        case .redis:
            AppCopy.current.text(
                "内存数据存储与缓存",
                "In-memory data store and cache"
            )
        case .elasticsearch:
            AppCopy.current.text(
                "分布式搜索与分析引擎",
                "Distributed search and analytics engine"
            )
        }
    }
}
