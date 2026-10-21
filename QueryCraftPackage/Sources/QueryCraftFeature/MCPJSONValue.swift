import Foundation

/// JSON shared by settings, desktop results and the independent MCP process.
/// Protocol SDK types stay in QueryCraftMCPPackage.
enum MCPJSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([MCPJSONValue]), object([String: MCPJSONValue])

    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var intValue: Int? { if case .int(let value) = self { value } else { nil } }
    var doubleValue: Double? { if case .double(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var arrayValue: [Self]? { if case .array(let value) = self { value } else { nil } }
    var objectValue: [String: Self]? { if case .object(let value) = self { value } else { nil } }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension MCPJSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(nilLiteral: ()) { self = .null }
}

struct MCPWireTool: Codable, Sendable {
    struct Annotations: Codable, Sendable {
        let readOnlyHint: Bool
        let destructiveHint: Bool
        let idempotentHint: Bool
    }
    let name: String
    let description: String
    let inputSchema: MCPJSONValue
    let annotations: Annotations
}
