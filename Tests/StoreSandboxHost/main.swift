import AppKit
import Foundation
@_spi(MCP) @testable import QueryCraftFeature
import QueryCraftMCPRuntime

// Development-only diagnostic host: no app initialization, CloudKit, credentials
// or user library access. It is never a dependency of the shipping Store target.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let directory = FileManager.default.temporaryDirectory.appending(path: "store-probe-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        guard ApplicationDistribution.current == .appStore else { throw ProbeError.failed("Wrong distribution") }
        guard let deniedPath = CommandLine.arguments.dropFirst().first else { throw ProbeError.failed("Missing external sandbox-denial fixture") }
        if (try? Data(contentsOf: URL(fileURLWithPath: deniedPath))) != nil {
            throw ProbeError.failed("Sandbox unexpectedly read the external fixture")
        }
        print("PASS sandbox blocks unselected external file")
        await DatabaseDriverManager.shared.loadInstalledDrivers()
        let loaded = await DatabaseDriverRegistry.shared.installedDatabaseTypes()
        guard Set(loaded.map(\.rawValue)) == Set(["mysql", "postgresql", "doris", "redis", "elasticsearch", "kafka", "milvus"]) else {
            throw ProbeError.failed("Driver load set: " + loaded.map(\.rawValue).sorted().joined(separator: ", "))
        }
        print("PASS seven signed drivers loaded inside sandbox")
        let ssh = try SSHPlugin(bundleURL: SSHPlugin.bundleURL(in: directory))
        withExtendedLifetime(ssh) { print("PASS signed SSH native ABI and renderer validation") }
        var policy = MCPPolicy()
        policy.enabled = true
        policy.http.port = Int.random(in: 49_152...65_535)
        try MCPPolicyStore(directory: directory).save(policy)
        let service = QueryCraftMCPEmbeddedService()
        try await service.start(directory: directory)
        do {
            var request = URLRequest(url: URL(string: policy.http.endpoint)!)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Sandbox probe","version":"1"}}}"#.utf8)
            let (_, denied) = try await URLSession.shared.data(for: request)
            guard (denied as? HTTPURLResponse)?.statusCode == 401 else { throw ProbeError.failed("MCP accepted an unauthorized request") }
            request.setValue("Bearer " + policy.http.token, forHTTPHeaderField: "Authorization")
            let (_, allowed) = try await URLSession.shared.data(for: request)
            guard (allowed as? HTTPURLResponse)?.statusCode == 200 else { throw ProbeError.failed("MCP authorized initialization failed") }
            try await service.stop()
        } catch {
            try? await service.stop()
            throw error
        }
        print("PASS sandbox MCP HTTP authorization and shutdown")
        let source = directory.appending(path: "skill-source")
        let parent = directory.appending(path: "skills")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("sandbox skill fixture".utf8).write(to: source.appending(path: "SKILL.md"))
        let grants = LocalFileAuthorization(directory: directory.appending(path: "grants"))
        try grants.remember(parent, readOnly: false)
        let lease = try grants.access(path: parent.path, writable: true)
        defer { withExtendedLifetime(lease) {} }
        let installer = MCPSkillInstallation(source: source)
        let destination = parent.appending(path: "querycraft")
        try await installer.install(at: destination)
        guard try await installer.status(at: destination) == .current else { throw ProbeError.failed("Skill install status") }
        try await installer.uninstall(at: destination)
        print("PASS sandbox local bookmark and Skill install/remove lifecycle")
        exit(EXIT_SUCCESS)
    } catch {
        print("FAIL " + String(describing: error))
        exit(EXIT_FAILURE)
    }
}
app.run()

enum ProbeError: Error { case failed(String) }
