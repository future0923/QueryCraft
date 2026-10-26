import Foundation
import Testing
@testable import QueryCraftFeature

struct ShellScriptTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "qc-shell-" + UUID().uuidString) }
    private func policy(_ root: URL, allowUpdate: Bool = true) throws {
        var value = MCPPolicy(); value.enabled = true; value.disabledTools = allowUpdate ? [] : ["shell_update"]
        try MCPPolicyStore(directory: root).save(value)
    }
    @Test func persistenceRevisionConflictsAndPrivateAtomicWrites() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ShellScriptStore(directory: root)
        let created = try store.create(name: "Deploy", description: "literal", script: "printf '你好\\n'\n")
        let other = ShellScriptStore(directory: root)
        #expect(try other.load() == [created])
        let edited = try other.update(id: created.id, revision: 1, name: "Health", description: nil, script: "printf ok")
        #expect(edited.revision == 2)
        #expect(throws: MCPFailure.self) { try store.update(id: created.id, revision: 1, name: nil, description: nil, script: "stale") }
        #expect(throws: MCPFailure.self) { try store.remove(id: created.id, revision: 1) }
        #expect(try store.load() == [edited])
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        try other.remove(id: created.id, revision: 2)
        #expect(try store.load().isEmpty)
    }
    @Test func boundsCorruptionAndSymlinksNeverEraseExistingData() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ShellScriptStore(directory: root)
        let record = try store.create(name: "original", description: "", script: "echo original")
        for script in ["", "   \n", "echo\0bad", String(repeating: "a", count: 65_537)] {
            #expect(throws: MCPFailure.self) { try store.update(id: record.id, revision: 1, name: nil, description: nil, script: script) }
        }
        #expect(try store.load() == [record])
        let corrupt = Data("invalid-json".utf8); try corrupt.write(to: store.url)
        #expect(throws: MCPFailure.self) { try store.create(name: "new", description: "", script: "echo new") }
        #expect(try Data(contentsOf: store.url) == corrupt)
        try FileManager.default.removeItem(at: store.url)
        let outside = root.appending(path: "outside"); try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: outside)
        #expect(throws: MCPFailure.self) { try store.create(name: "new", description: "", script: "echo new") }
        #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
    }
    @Test func noPluginCRUDPolicyAndDelegatedTools() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try policy(root)
        let runtime = MCPRuntime(directory: root)
        let tools = try await runtime.tools()
        #expect(MCPToolCatalog.shellTools.allSatisfy { name in tools.contains { $0.name == "querycraft_" + name } })
        let created = try await runtime.call("querycraft_shell_create", arguments: ["name": "健康检查", "script": "printf ok\n"])
        let id = try #require(created.objectValue?["script_id"]?.stringValue)
        #expect(created.objectValue?["revision"] == 1)
        let read = try await runtime.call("querycraft_plugin_call", arguments: ["plugin_id": "shell", "tool": "shell_get", "arguments": .object(["script_id": .string(id)])])
        #expect(read.objectValue?["script"] == "printf ok\n")
        let schemas = try await runtime.call("querycraft_plugin_tools", arguments: ["plugin_id": "shell"])
        #expect(schemas.arrayValue?.count == 5)
        try policy(root, allowUpdate: false)
        _ = try await runtime.call("querycraft_shell_list", arguments: [:])
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_shell_update", arguments: ["script_id": .string(id), "expected_revision": 1, "script": "false"]) }
        var settings = try MCPPolicyStore(directory: root).load(); settings.disabledTools = ["shell_get"]
        try MCPPolicyStore(directory: root).save(settings)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_plugin_call", arguments: ["plugin_id": "shell", "tool": "shell_get", "arguments": .object(["script_id": .string(id)])]) }
        #expect(try ShellScriptStore(directory: root).load().first?.revision == 1)
        await runtime.shutdown()
    }
    @Test func boundedUnicodeWindowsAndPagination() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try policy(root)
        let scripts = ShellScriptStore(directory: root)
        let text = String(repeating: "你👩‍💻'\\\n", count: 1500)
        let record = try scripts.create(name: "unicode", description: "", script: text)
        for i in 0..<4 { _ = try scripts.create(name: "script \(i)", description: "", script: "echo \(i)") }
        var settings = try MCPPolicyStore(directory: root).load(); settings.maximumResultBytes = 1024
        try MCPPolicyStore(directory: root).save(settings)
        let runtime = MCPRuntime(directory: root)
        let first = try await runtime.call("querycraft_shell_list", arguments: ["max_records": 2])
        #expect(first.objectValue?["next_offset"] == 2)
        #expect(first.objectValue?["scripts"]?.arrayValue?.count == 2)
        var result = "", offset = 0
        while true {
            let value = try await runtime.call("querycraft_shell_get", arguments: ["script_id": .string(record.id.uuidString), "script_offset": .int(offset), "max_chars": 65_536])
            #expect(try JSONEncoder().encode(value).count <= 1024)
            result += try #require(value.objectValue?["script"]?.stringValue)
            guard let next = value.objectValue?["next_offset"]?.intValue else { break }
            #expect(next > offset); offset = next
        }
        #expect(result == text)
        let largeCharacter = try scripts.create(name: "grapheme", description: "", script: "a" + String(repeating: "\u{301}", count: 1500))
        await #expect(throws: MCPFailure.self) {
            _ = try await runtime.call("querycraft_shell_get", arguments: ["script_id": .string(largeCharacter.id.uuidString)])
        }
        await runtime.shutdown()
    }
    @Test func savedSourceNeverExecutesAndDoesNotGrantSSH() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try policy(root)
        let transport = RecordingSSHTransport()
        let runtime = MCPRuntime(directory: root, sshTransport: transport)
        _ = try await runtime.call("querycraft_shell_create", arguments: ["name": "literal", "script": "rm -rf /tmp/not-executed"])
        #expect(await transport.requests.isEmpty)
        #expect(try MCPPolicyStore(directory: root).load().ssh == nil)
        await runtime.shutdown()
    }
}
