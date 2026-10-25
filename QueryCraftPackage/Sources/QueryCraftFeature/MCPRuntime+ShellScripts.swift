import Foundation

extension MCPRuntime {
    func callShellScript(_ tool: String, args: [String: MCPJSONValue], policy: MCPPolicy) throws -> MCPJSONValue {
        let scripts = ShellScriptStore(directory: store.url.deletingLastPathComponent())
        if !MCPToolCatalog.shellReads.contains(tool), policy.mode != .fullAccess {
            throw MCPFailure("Editing the local Shell script library requires global full access.", code: .accessDenied)
        }
        if tool == "shell_create" {
            return try scripts.create(name: args.requiredString("name"), description: args.string("description") ?? "", script: args.requiredString("script")).receipt
        }
        if tool == "shell_list" {
            let offset = args.integer("offset", default: 0), limit = args.integer("max_records", default: 20)
            guard (0...128).contains(offset), (1...50).contains(limit) else { throw MCPFailure("Invalid script list limits.") }
            let records = try scripts.load().sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
            guard offset <= records.count else { throw MCPFailure("Offset exceeds current library. List again from offset 0.") }
            var page: [MCPJSONValue] = []
            func value(_ next: Int) -> MCPJSONValue {
                .object(["scripts": .array(page), "total": .int(records.count),
                         "next_offset": next < records.count ? .int(next) : .null])
            }
            for record in records.dropFirst(offset).prefix(limit) {
                page.append(record.value)
                if try JSONEncoder().encode(value(offset + page.count)).count > policy.maximumResultBytes {
                    page.removeLast()
                    guard !page.isEmpty else { throw MCPFailure("A script summary exceeds the result budget. Increase maximumResultBytes.", code: .resultTooLarge) }
                    break
                }
            }
            return value(offset + page.count)
        }
        guard let id = UUID(uuidString: try args.requiredString("script_id")) else { throw MCPFailure("Use an exact saved script UUID.") }
        if tool == "shell_update" {
            return try scripts.update(id: id, revision: args.integer("expected_revision", default: 0), name: args.string("name"),
                                      description: args.string("description"), script: args.string("script")).receipt
        }
        if tool == "shell_delete" {
            try scripts.remove(id: id, revision: args.integer("expected_revision", default: 0))
            return .object(["script_id": .string(id.uuidString), "deleted": true])
        }
        guard let record = try scripts.load().first(where: { $0.id == id }) else { throw MCPFailure("Shell script not found.") }
        let offset = args.integer("script_offset", default: 0), limit = args.integer("max_chars", default: 4000)
        guard offset >= 0, offset <= record.script.count, (1...65_536).contains(limit) else { throw MCPFailure("Invalid script read window.") }
        let remaining = record.script.dropFirst(offset)
        var count = min(limit, remaining.count)
        while true {
            var fields = record.value.objectValue!
            fields["script"] = .string(String(remaining.prefix(count)))
            fields["script_offset"] = .int(offset)
            fields["total_chars"] = .int(record.script.count)
            fields["next_offset"] = offset + count < record.script.count ? .int(offset + count) : .null
            let value = MCPJSONValue.object(fields)
            if try JSONEncoder().encode(value).count <= policy.maximumResultBytes {
                guard count > 0 || remaining.isEmpty else { throw MCPFailure("A script character exceeds the result budget. Increase maximumResultBytes.", code: .resultTooLarge) }
                return value
            }
            guard count > 0 else { throw MCPFailure("Script metadata exceeds the result budget. Increase maximumResultBytes.", code: .resultTooLarge) }
            count /= 2
        }
    }
}
