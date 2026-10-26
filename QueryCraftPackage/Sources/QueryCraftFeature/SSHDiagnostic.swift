import Foundation
import CQueryCraftSSHPluginAPI

/// Only host-owned IDs and fixed stage names are exposed. Never include native
/// error strings, key paths, socket paths or authentication payloads.
struct SSHDiagnostic: Codable, Sendable {
    let endpointIndex: Int
    let hopCount: Int
    let phase: String
    let connectionID: UUID
    let viaConnectionID: UUID?
    private static let phases: [UInt32: String] = [1: "preparing", 2: "resolve", 3: "connect", 4: "handshake",
        5: "host_key", 6: "authentication", 7: "forwarding", 8: "pool", 9: "command", 10: "sftp"]
    var isValid: Bool {
        (0...4).contains(hopCount) && (1...(hopCount + 1)).contains(endpointIndex)
            && Self.phases.values.contains(phase)
            && (phase == "forwarding" ? endpointIndex > 1 && viaConnectionID != nil : viaConnectionID == nil)
    }

    init?(value: MCPJSONValue) {
        guard let object = value.objectValue, let index = object["endpoint_index"]?.intValue,
              let count = object["jump_count"]?.intValue, let phase = object["phase"]?.stringValue,
              let id = object["connection_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
        endpointIndex = index; hopCount = count; self.phase = phase; connectionID = id
        viaConnectionID = object["via_connection_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        guard isValid else { return nil }
    }

    init?(_ raw: qc_ssh_diagnostic, endpoints: [SSHConnection]) {
        guard raw.size == MemoryLayout<qc_ssh_diagnostic>.size, raw.hop_count <= 4,
              endpoints.count == Int(raw.hop_count) + 1, raw.endpoint_index > 0,
              raw.endpoint_index <= endpoints.count, let phase = Self.phases[raw.phase],
              phase != "forwarding" || raw.endpoint_index > 1 else { return nil }
        endpointIndex = Int(raw.endpoint_index); hopCount = Int(raw.hop_count); self.phase = phase
        connectionID = endpoints[endpointIndex - 1].id
        viaConnectionID = phase == "forwarding" ? endpoints[endpointIndex - 2].id : nil
    }
    var message: String {
        "SSH endpoint \(endpointIndex)/\(hopCount + 1) (\(endpointIndex == hopCount + 1 ? "target" : "jump")), stage: \(phase)."
    }
    var value: MCPJSONValue {
        var value: [String: MCPJSONValue] = ["endpoint_index": .int(endpointIndex), "jump_count": .int(hopCount),
            "role": .string(endpointIndex == hopCount + 1 ? "target" : "jump"), "phase": .string(phase),
            "connection_id": .string(connectionID.uuidString)]
        if let viaConnectionID { value["via_connection_id"] = .string(viaConnectionID.uuidString) }
        if phase == "forwarding" { value["resolution_scope"] = "forwarding_server" }
        return .object(value)
    }
}
