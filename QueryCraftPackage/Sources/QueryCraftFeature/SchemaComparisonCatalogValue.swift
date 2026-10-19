import Foundation

/// Lossless catalog values used by the native Swift comparison engine.
indirect enum SchemaEngineJSON: Codable, Equatable, Sendable {
    case object([String: Self]), array([Self]), string(String), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v = dictionary; v[key] = newValue; self = .object(v) }
    }
    var dictionary: [String: Self] { if case .object(let v) = self { v } else { [:] } }
    var array: [Self] { if case .array(let v) = self { v } else { [] } }
    var string: String { if case .string(let v) = self { v } else { "" } }
    var display: String {
        switch self {
        case .string(let v): v
        case .number(let v): v.formatted(.number.grouping(.never))
        case .bool(let v): v ? AppCopy.current.text("是", "Yes") : AppCopy.current.text("否", "No")
        case .null: "—"
        case .array(let v): v.map(\.display).joined(separator: ", ")
        case .object: String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""
        }
    }
}

struct SchemaEngineFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
