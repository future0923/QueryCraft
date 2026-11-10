import CloudKit
import Foundation

/// Values exchanged by iCloud sync. macOS and iOS keep their own local
/// storage; these types are the shared wire format in the private CloudKit
/// database. Fields owned by only one platform are optional groups so the
/// other platform preserves them instead of erasing them.
enum CloudSyncEntity: String, CaseIterable, Codable, Sendable {
    case connectionGroup = "ConnectionGroup"
    case connection = "Connection"
    case savedQuery = "SavedQuery"
    case snippet = "Snippet"

    /// Parents are applied before children inside one fetched batch.
    var applyOrder: Int {
        switch self {
        case .connectionGroup: 0
        case .connection: 1
        case .savedQuery: 2
        case .snippet: 3
        }
    }
}

struct CloudSyncKey: Hashable, Codable, Sendable, CustomStringConvertible {
    let entity: CloudSyncEntity
    let id: UUID

    static let zoneName = "QueryCraft"

    var recordName: String { "\(entity.rawValue).\(id.uuidString)" }
    var description: String { recordName }

    init(entity: CloudSyncEntity, id: UUID) {
        self.entity = entity
        self.id = id
    }

    init?(recordName: String) {
        let parts = recordName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let entity = CloudSyncEntity(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        self.init(entity: entity, id: id)
    }

    func recordID(zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }
}

/// A password that a device may not be able to read right now (for example
/// a locked Keychain). `.unavailable` keeps whatever iCloud already has.
enum CloudSyncSecret: Equatable, Sendable {
    case none
    case value(String)
    case unavailable
}

struct CloudSyncConnection: Equatable, Sendable {
    struct DesktopFields: Equatable, Sendable {
        var groupID: UUID?
        var sortIndex: Int
        var databaseProduct: String
        var kafkaSASLMechanism: String?
        var createdAt: Date
    }

    struct MobileFields: Equatable, Sendable {
        var schemaName: String?
    }

    var id: UUID
    var name: String
    var databaseType: String
    var host: String
    var port: Int
    var username: String
    var authenticationMethod: String
    var defaultDatabase: String?
    var tlsMode: String
    var storesCredential: Bool
    var secret: CloudSyncSecret
    /// nil when the local platform does not own these fields.
    var desktop: DesktopFields?
    var mobile: MobileFields?
}

struct CloudSyncConnectionGroup: Equatable, Sendable {
    var id: UUID
    var name: String
    var sortIndex: Int
    var createdAt: Date
}

struct CloudSyncSavedQuery: Equatable, Sendable {
    var id: UUID
    var connectionID: UUID
    var defaultDatabase: String?
    var name: String
    var sql: String
    var createdAt: Date
    var updatedAt: Date
}

struct CloudSyncSnippet: Equatable, Sendable {
    var id: UUID
    var name: String
    var trigger: String
    var content: String
    var isEnabled: Bool
    var sortIndex: Int
}

enum CloudSyncValue: Equatable, Sendable {
    case connectionGroup(CloudSyncConnectionGroup)
    case connection(CloudSyncConnection)
    case savedQuery(CloudSyncSavedQuery)
    case snippet(CloudSyncSnippet)

    var key: CloudSyncKey {
        switch self {
        case let .connectionGroup(value): .init(entity: .connectionGroup, id: value.id)
        case let .connection(value): .init(entity: .connection, id: value.id)
        case let .savedQuery(value): .init(entity: .savedQuery, id: value.id)
        case let .snippet(value): .init(entity: .snippet, id: value.id)
        }
    }
}

enum CloudSyncRemoteChange: Equatable, Sendable {
    case upsert(CloudSyncValue)
    case delete(CloudSyncKey)

    var key: CloudSyncKey {
        switch self {
        case let .upsert(value): value.key
        case let .delete(key): key
        }
    }
}

enum CloudSyncRecordCodingError: Error, Equatable {
    case invalidRecordName(String)
    case missingField(String)
}

/// Field names are part of the CloudKit schema; never rename them.
enum CloudSyncRecordCoder {
    static let modifiedAtField = "modifiedAt"
    static let secretField = "secret"

    /// Writes the value into `record`, keeping fields the local platform does
    /// not own. `modifiedAt` drives last-writer-wins conflict resolution.
    static func encode(_ value: CloudSyncValue, modifiedAt: Date, into record: CKRecord) {
        record[modifiedAtField] = modifiedAt as NSDate
        switch value {
        case let .connectionGroup(group):
            record["name"] = group.name as NSString
            record["sortIndex"] = group.sortIndex as NSNumber
            record["createdAt"] = group.createdAt as NSDate
        case let .connection(connection):
            record["name"] = connection.name as NSString
            record["databaseType"] = connection.databaseType as NSString
            record["host"] = connection.host as NSString
            record["port"] = connection.port as NSNumber
            record["username"] = connection.username as NSString
            record["authenticationMethod"] = connection.authenticationMethod as NSString
            record["defaultDatabase"] = connection.defaultDatabase.map { $0 as NSString }
            record["tlsMode"] = connection.tlsMode as NSString
            record["storesCredential"] = connection.storesCredential as NSNumber
            switch connection.secret {
            case .none:
                record.encryptedValues[secretField] = nil
            case let .value(secret):
                record.encryptedValues[secretField] = secret as NSString
            case .unavailable:
                break
            }
            if let desktop = connection.desktop {
                record["groupID"] = desktop.groupID.map { $0.uuidString as NSString }
                record["sortIndex"] = desktop.sortIndex as NSNumber
                record["databaseProduct"] = desktop.databaseProduct as NSString
                record["kafkaSASLMechanism"] = desktop.kafkaSASLMechanism.map { $0 as NSString }
                record["createdAt"] = desktop.createdAt as NSDate
            }
            if let mobile = connection.mobile {
                record["schemaName"] = mobile.schemaName.map { $0 as NSString }
            }
        case let .savedQuery(query):
            record["connectionID"] = query.connectionID.uuidString as NSString
            record["defaultDatabase"] = query.defaultDatabase.map { $0 as NSString }
            record["name"] = query.name as NSString
            record["sql"] = query.sql as NSString
            record["createdAt"] = query.createdAt as NSDate
            record["updatedAt"] = query.updatedAt as NSDate
        case let .snippet(snippet):
            record["name"] = snippet.name as NSString
            record["trigger"] = snippet.trigger as NSString
            record["content"] = snippet.content as NSString
            record["isEnabled"] = snippet.isEnabled as NSNumber
            record["sortIndex"] = snippet.sortIndex as NSNumber
        }
    }

    static func modifiedAt(of record: CKRecord) -> Date {
        record[modifiedAtField] as? Date ?? .distantPast
    }

    static func decode(_ record: CKRecord) throws -> CloudSyncValue {
        guard let key = CloudSyncKey(recordName: record.recordID.recordName),
              key.entity.rawValue == record.recordType
        else {
            throw CloudSyncRecordCodingError.invalidRecordName(record.recordID.recordName)
        }
        func string(_ field: String) throws -> String {
            guard let value = record[field] as? String else {
                throw CloudSyncRecordCodingError.missingField(field)
            }
            return value
        }
        func optionalString(_ field: String) -> String? { record[field] as? String }
        func int(_ field: String, default value: Int? = nil) throws -> Int {
            if let number = record[field] as? NSNumber { return number.intValue }
            if let value { return value }
            throw CloudSyncRecordCodingError.missingField(field)
        }
        func bool(_ field: String, default value: Bool) -> Bool {
            (record[field] as? NSNumber)?.boolValue ?? value
        }
        func date(_ field: String) -> Date {
            record[field] as? Date ?? record.creationDate ?? .now
        }

        switch key.entity {
        case .connectionGroup:
            return .connectionGroup(.init(
                id: key.id,
                name: try string("name"),
                sortIndex: try int("sortIndex", default: 0),
                createdAt: date("createdAt")
            ))
        case .connection:
            let databaseType = try string("databaseType")
            let storesCredential = bool("storesCredential", default: false)
            let secret = record.encryptedValues[secretField] as? String
            return .connection(.init(
                id: key.id,
                name: try string("name"),
                databaseType: databaseType,
                host: try string("host"),
                port: try int("port"),
                username: optionalString("username") ?? "",
                authenticationMethod: optionalString("authenticationMethod") ?? "usernamePassword",
                defaultDatabase: optionalString("defaultDatabase"),
                tlsMode: try string("tlsMode"),
                storesCredential: storesCredential,
                secret: storesCredential ? secret.map(CloudSyncSecret.value) ?? .none : .none,
                desktop: .init(
                    groupID: optionalString("groupID").flatMap(UUID.init(uuidString:)),
                    sortIndex: try int("sortIndex", default: 0),
                    databaseProduct: optionalString("databaseProduct") ?? databaseType,
                    kafkaSASLMechanism: optionalString("kafkaSASLMechanism"),
                    createdAt: date("createdAt")
                ),
                mobile: .init(schemaName: optionalString("schemaName"))
            ))
        case .savedQuery:
            guard let connectionID = UUID(uuidString: try string("connectionID")) else {
                throw CloudSyncRecordCodingError.missingField("connectionID")
            }
            return .savedQuery(.init(
                id: key.id,
                connectionID: connectionID,
                defaultDatabase: optionalString("defaultDatabase"),
                name: try string("name"),
                sql: try string("sql"),
                createdAt: date("createdAt"),
                updatedAt: date("updatedAt")
            ))
        case .snippet:
            return .snippet(.init(
                id: key.id,
                name: try string("name"),
                trigger: try string("trigger"),
                content: try string("content"),
                isEnabled: bool("isEnabled", default: true),
                sortIndex: try int("sortIndex", default: 0)
            ))
        }
    }
}
