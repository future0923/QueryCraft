#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

enum TransferContent: String, Codable, CaseIterable, Identifiable, Sendable {
    case structureAndData, structureOnly, dataOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .structureAndData: AppCopy.current.text("结构和数据", "Structure and data")
        case .structureOnly: AppCopy.current.text("仅结构", "Structure only")
        case .dataOnly: AppCopy.current.text("仅数据", "Data only")
        }
    }
}

enum TransferStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case append, overwrite, upsert, rebuild
    var id: String { rawValue }
    var title: String {
        switch self {
        case .append: AppCopy.current.text("追加（保留已有对象）", "Append (keep existing objects)")
        case .overwrite: AppCopy.current.text("覆盖数据", "Overwrite data")
        case .upsert: AppCopy.current.text("更新或插入（Upsert）", "Update or insert (Upsert)")
        case .rebuild: AppCopy.current.text("重建结构和数据", "Rebuild structure and data")
        }
    }
}

enum TransferNameCase: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve, lower, upper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .preserve: AppCopy.current.text("保持原样", "Preserve")
        case .lower: AppCopy.current.text("转小写", "Lowercase")
        case .upper: AppCopy.current.text("转大写", "Uppercase")
        }
    }
    func apply(_ name: String) -> String {
        switch self { case .preserve: name; case .lower: name.lowercased(); case .upper: name.uppercased() }
    }
}

enum TransferObjectKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case table, view, materializedView, procedure, function, trigger, sequence, event
    var id: String { rawValue }
    var title: String {
        switch self {
        case .table: AppCopy.current.text("表", "Tables")
        case .view: AppCopy.current.text("视图", "Views")
        case .materializedView: AppCopy.current.text("物化视图", "Materialized views")
        case .procedure: AppCopy.current.text("存储过程", "Procedures")
        case .function: AppCopy.current.text("函数", "Functions")
        case .trigger: AppCopy.current.text("触发器", "Triggers")
        case .sequence: AppCopy.current.text("序列", "Sequences")
        case .event: AppCopy.current.text("事件", "Events")
        }
    }
    var order: Int {
        switch self {
        case .sequence: 0
        case .function: 1
        case .procedure: 2
        case .table: 3
        case .view: 4
        case .materializedView: 5
        case .trigger: 6
        case .event: 7
        }
    }
}

struct TransferObject: Codable, Hashable, Identifiable, Sendable {
    let kind: TransferObjectKind
    let name: String
    // OIDs and routine signatures come from catalogs, never from display-name splitting.
    var identity: String = ""
    var parentTable: String? = nil
    var signature: String = ""
    var argumentTypes: String = ""
    var id: String { "\(kind.rawValue):\(identity.isEmpty ? name : identity)" }
}

struct TransferEndpoint: Codable, Equatable, Sendable {
    var profileID: UUID?
    var database = ""
    var schema = ""
    var namespace: String { schema.isEmpty ? database : schema }
}

struct DataTransferConfiguration: Codable, Equatable, Sendable {
    var source = TransferEndpoint()
    var target = TransferEndpoint()
    var objects: [TransferObject] = []
    var content = TransferContent.structureAndData
    var strategy = TransferStrategy.append
    var nameCase = TransferNameCase.preserve
    var batchSize = 1000
    var operationTimeoutSeconds: Int? = nil
    var tableFilters: [String: String] = [:]

    mutating func swapEndpoints() {
        let previous = source; source = target; target = previous
        objects = []; tableFilters = [:]
    }

    mutating func pruneSelection(sourceType: DatabaseType?, targetType: DatabaseType?) {
        let selected = objects.filter { TransferCapabilities.objectEnabled($0, content: content, source: sourceType, target: targetType) }
        objects = selected
        if content == .dataOnly && strategy == .rebuild { strategy = .append }
        if content == .structureOnly && (strategy == .upsert || strategy == .overwrite && !(sourceType == .mysql && targetType == .mysql && selected.contains { $0.kind != .table })) { strategy = .append }
    }

    func validate(sourceType: DatabaseType, targetType: DatabaseType) throws {
        guard TransferCapabilities.canRead(sourceType), TransferCapabilities.canWrite(targetType) else {
            throw TransferFailure("源或目标驱动不支持关系对象传输。", "The source or target driver does not support relational transfers.")
        }
        guard source.profileID != nil, target.profileID != nil, !source.database.isEmpty, !target.database.isEmpty,
              !objects.isEmpty else { throw TransferFailure("请选择来源、目标和至少一个对象。", "Choose a source, target and at least one object.") }
        guard source != target else { throw TransferFailure("源和目标不能是同一位置。", "Source and target must be different locations.") }
        guard (100...10000).contains(batchSize), operationTimeoutSeconds.map({ (0...3600).contains($0) }) ?? true else {
            throw TransferFailure("批大小须为 100～10000；超时须为 0～3600 秒。", "Batch size must be 100–10000; timeout must be 0–3600 seconds.")
        }
        guard content != .dataOnly || strategy != .rebuild else {
            throw TransferFailure("仅数据模式不能重建结构。", "Data-only transfers cannot rebuild structures.")
        }
        guard content != .structureOnly || strategy == .append || strategy == .rebuild
                || strategy == .overwrite && sourceType == .mysql && targetType == .mysql && objects.contains(where: { $0.kind != .table }) else {
            throw TransferFailure("仅结构模式请选择保留已有对象或重建。", "For structure-only transfers, choose keep existing objects or rebuild.")
        }
        guard Set(objects.map(\.id)).count == objects.count else { throw TransferFailure("对象选择重复。", "Duplicate object selection.") }
        let tableNames = objects.filter { $0.kind == .table }.map { nameCase.apply($0.name) }
        guard Set(tableNames.map { $0.lowercased() }).count == tableNames.count else {
            throw TransferFailure("大小写转换后的目标表名冲突。", "Target table names conflict after case conversion.")
        }
        for object in objects {
            guard content != .dataOnly || object.kind == .table,
                  TransferCapabilities.supports(object.kind, source: sourceType, target: targetType) else {
                throw TransferFailure("所选驱动组合不支持对象：\(object.name)。", "This driver pair does not support object: \(object.name).")
            }
        }
        for (table, filter) in tableFilters where objects.contains(where: { $0.kind == .table && $0.name == table }) {
            try TransferSQL.validateFilter(filter)
        }
    }
}

enum TransferCapabilities {
    static func objectEnabled(_ object: TransferObject, content: TransferContent, source: DatabaseType?, target: DatabaseType?) -> Bool {
        guard let source else { return false }
        if content == .dataOnly && object.kind != .table { return false }
        guard let target else { return object.kind == .table }
        return supports(object.kind, source: source, target: target)
    }
    static func canRead(_ type: DatabaseType) -> Bool { [.mysql, .postgresql, .doris].contains(type) }
    static func canWrite(_ type: DatabaseType) -> Bool { [.mysql, .postgresql].contains(type) }
    static func supports(_ kind: TransferObjectKind, source: DatabaseType, target: DatabaseType) -> Bool {
        guard canRead(source), canWrite(target) else { return false }
        if kind == .table { return true }
        guard source == target else { return false }
        if source == .mysql { return ![.materializedView, .sequence].contains(kind) }
        return kind != .event
    }
    static func reason(_ type: DatabaseType) -> String {
        switch type {
        case .mysql, .postgresql: AppCopy.current.text("支持源和目标", "Source and target supported")
        case .doris: AppCopy.current.text("当前驱动只读，仅支持作为来源", "Current driver is read-only; source only")
        case .redis: AppCopy.current.text("Key、类型和 TTL 需要专用迁移链路", "Keys, types and TTL require a dedicated transfer")
        case .elasticsearch: AppCopy.current.text("索引、Mapping 和文档需要专用迁移链路", "Indices, mappings and documents require a dedicated transfer")
        case .kafka: AppCopy.current.text("消息和分区需要专用转发链路", "Messages and partitions require a dedicated forwarding path")
        }
    }
}

struct TransferFailure: LocalizedError, Sendable {
    let message: String
    init(_ zh: String, _ en: String) { message = AppCopy.current.text(zh, en) }
    var errorDescription: String? { message }
}
