import Foundation

struct SSHFileRequest: Sendable {
    enum Operation: UInt32, Sendable { case stat = 1, list, read, upload, download, mkdir, move, unlink, rmdir }
    let operation: Operation
    let remotePath: String
    var localPath: String? = nil
    var offset = 0
    var maximumTransferBytes = 67_108_864
    var maximumEntries = 100
    var overwrite = false
    var temporaryPath: String? = nil
    var progress: (@Sendable (SSHTransferProgress) -> Void)? = nil
    func validate() throws {
        if operation.rawValue >= Operation.mkdir.rawValue {
            try Self.validateMutationPath(remotePath)
            if operation == .move {
                guard let temporaryPath, temporaryPath != remotePath else { throw MCPFailure("Move requires a distinct destination path.") }
                try Self.validateMutationPath(temporaryPath)
            }
        }
        let paths = [remotePath, localPath, temporaryPath].compactMap { $0 }
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }),
              (0...9_007_199_254_740_991).contains(offset), (1...500).contains(maximumEntries),
              (1...1_073_741_824).contains(maximumTransferBytes),
              ![Operation.upload, .download].contains(operation) || localPath != nil,
              operation != .upload || (temporaryPath != nil && temporaryPath != remotePath) else {
            throw MCPFailure("Use absolute paths, valid byte/entry limits and an exact local path for transfers.")
        }
    }
    static func validateMutationPath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"), !path.contains("\0"), path.utf8.count <= 4096,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MCPFailure("Use an exact absolute path without root, trailing slash or dot components.")
        }
    }
    func result(_ result: SSHResult, encoding: String = "utf8") throws -> MCPJSONValue {
        try result.validate()
        switch operation {
        case .mkdir, .move, .unlink, .rmdir:
            return .object(["status": "completed", "path": .string(remotePath), "destination_path": operation == .move ? temporaryPath.map(MCPJSONValue.string) ?? .null : .null, "automatic_retry": false])
        case .stat: return .object(try attributes(result.stderr))
        case .list:
            let entries = try String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map { row -> MCPJSONValue in
                let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 5, let bytes = Data(base64Encoded: String(fields[0])) else { throw MCPFailure("Invalid SFTP directory result.", code: .driverFailure) }
                var value = try attributes(Data(fields.dropFirst().joined(separator: "\t").utf8))
                value["name_base64"] = .string(bytes.base64EncodedString())
                value["name"] = String(data: bytes, encoding: .utf8).map(MCPJSONValue.string) ?? .null
                return .object(value)
            }
            if entries.isEmpty && result.truncated { throw MCPFailure("Increase the MCP result budget to fit a directory entry.", code: .resultTooLarge) }
            return .object(["path": .string(remotePath), "entries": .array(entries), "truncated": .bool(result.truncated),
                "next_offset": result.truncated ? .int(offset + entries.count) : .null,
                "ordering": "server order; directory changes can alter pagination"])
        case .read:
            guard ["utf8", "base64"].contains(encoding) else { throw MCPFailure("Choose utf8 or base64 encoding.") }
            if encoding == "utf8", String(data: result.stdout, encoding: .utf8) == nil {
                throw MCPFailure("This byte window is not valid UTF-8. Use encoding=base64 for binary files or UTF-8 boundaries.")
            }
            var value = try attributes(result.stderr)
            value["path"] = .string(remotePath); value["encoding"] = .string(encoding)
            value["content"] = .string(encoding == "base64" ? result.stdout.base64EncodedString() : String(decoding: result.stdout, as: UTF8.self))
            value["offset"] = .int(offset); value["bytes_read"] = .int(result.stdout.count)
            value["truncated"] = .bool(result.truncated)
            value["next_offset"] = result.truncated ? .int(offset + result.stdout.count) : .null
            return .object(value)
        case .upload, .download:
            let hash = String(decoding: result.stdout, as: UTF8.self)
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw MCPFailure("Transfer completed but its digest is unavailable. Check the destination before repeating it.", code: .outcomeUnknown) }
            return .object(["status": "completed", "remote_path": .string(remotePath), "local_path": localPath.map(MCPJSONValue.string) ?? .null,
                "bytes_transferred": .int(Int(clamping: result.outputBytes)), "sha256": .string(hash), "overwrite_allowed": .bool(overwrite), "automatic_retry": false])
        }
    }
    private func attributes(_ data: Data) throws -> [String: MCPJSONValue] {
        let fields = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard fields.count == 4, let flags = UInt64(fields[0]), let mode = Int(fields[2]), UInt64(fields[1]) != nil, UInt64(fields[3]) != nil else {
            throw MCPFailure("Invalid SFTP attributes.", code: .driverFailure)
        }
        func number(_ text: Substring) -> MCPJSONValue { Int(text).map(MCPJSONValue.int) ?? .string(String(text)) }
        let type: String = switch mode & 0o170000 {
        case 0o100000: "file"
        case 0o040000: "directory"
        case 0o120000: "symlink"
        default: "other"
        }
        return ["type": .string(flags & 4 != 0 ? type : "unknown"), "size_bytes": flags & 1 != 0 ? number(fields[1]) : .null,
            "permissions": flags & 4 != 0 ? .string(String(mode & 0o7777, radix: 8)) : .null,
            "modified_at_unix": flags & 8 != 0 ? number(fields[3]) : .null]
    }
}
