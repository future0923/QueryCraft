import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor struct SSHShellScriptsTests {
    private func fixture() throws -> (URL, SSHConnection, ShellScript) {
        let root = FileManager.default.temporaryDirectory.appending(path: "qc-terminal-scripts-" + UUID().uuidString)
        let profile = SSHConnection(id: UUID(), name: "fixture", host: "192.0.2.10", port: 22, username: "tester",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            privateKeyPath: "/fixture/key", storesCredential: false)
        try SSHConnectionStore(directory: root).insert(profile)
        let script = try ShellScriptStore(directory: root).create(name: "literal", description: "fixture", script: "printf '%s\\n' \"a'b $HOME 中文\"\n")
        return (root, profile, script)
    }
    @Test func scriptsAreFirstAndDefault() {
        #expect(SSHTerminalWorkspace().inspectorTab == .scripts)
        #expect(SSHTerminalInspectorTab.allCases == [.scripts, .connection])
    }
    @Test func simpleSnippetIsInsertedLiterallyWithoutReturn() throws {
        #expect(try SSHScriptTerminalInput.command("cd /tmp\n") == "cd /tmp")
        #expect(try SSHScriptTerminalInput.command("printf '%s' \"a'b 中文\"") == "printf '%s' \"a'b 中文\"")
        #expect(throws: (any Error).self) { try SSHScriptTerminalInput.command("echo invalid\0") }
    }
    @Test func multilineQuotesUnicodeAndBackslashesSurviveEncoding() async throws {
        let source = "value=\"a'b 中文\"\nprintf '%s\\n' \"$value\"\nprintf '%s' '\\c stays literal'\n"
        let command = try SSHScriptTerminalInput.command(source)
        #expect(!command.contains("\r") && !command.contains("\n"))
        let output = try await MCPProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
        #expect(output == "a'b 中文\n\\c stays literal")
    }
    @Test func largeScriptUsesBoundedPhysicalLinesAndStillRunsExactly() async throws {
        let expected = String(repeating: "中'a\\", count: 5000)
        let source = "printf '%s' " + SSHTaskCommand.shellQuote(expected) + "\n"
        #expect(source.utf8.count <= 65_536)
        let command = try SSHScriptTerminalInput.command(source)
        #expect(command.split(separator: "\n").allSatisfy { $0.utf8.count < 255 })
        let output = try await MCPProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
        #expect(output == expected)
    }
    @Test func reviewedLibraryAndLiveRouteMustStillMatch() async throws {
        let (root, profile, script) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = SSHConnectionService(directory: root)
        try await service.validateTerminalScript(script, endpoints: [profile])
        _ = try ShellScriptStore(directory: root).update(id: script.id, revision: 1, name: nil, description: nil, script: "echo changed")
        do { try await service.validateTerminalScript(script, endpoints: [profile]); Issue.record("stale source accepted") }
        catch { #expect(MCPFailure.normalized(error).code == .sessionBusy) }
        let latest = try #require(ShellScriptStore(directory: root).load().first)
        var changed = profile; changed.host = "192.0.2.11"
        try SSHConnectionStore(directory: root).replace(changed, expecting: profile)
        do { try await service.validateTerminalScript(latest, endpoints: [profile]); Issue.record("old terminal route accepted") }
        catch { #expect(MCPFailure.normalized(error).code == .sessionBusy) }
    }
    @Test func disconnectedTerminalNeverQueuesScriptInput() throws {
        let (root, profile, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = SSHTerminalSession(profile: profile); session.state = .closed
        #expect(throws: (any Error).self) { try session.insertScript("echo fixture", execute: true) }
    }
}
