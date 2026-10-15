import CryptoKit
import Foundation
@testable import QueryCraftFeature

enum MCPComponentCheck {
    static func run(source: URL, root: URL, serving: URL, baseURL: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: serving, withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey()
        let host = MCPComponentHost(appVersion: "0.1.9")
        let catalog = MCPComponentCatalog(baseURL: baseURL, publicKey: key.publicKey.rawRepresentation, allowsLocalHTTP: true)
        let installation = MCPInstallation(root: root.appending(path: "MCP"), catalog: catalog, host: host)
        let identity = ProcessInfo.processInfo.environment["QC_MCP_SIGNING_IDENTITY"]!
        let keychain = ProcessInfo.processInfo.environment["QC_MCP_SIGNING_KEYCHAIN"]!
        func sign(_ app: URL) async throws {
            _ = try await MCPProcess.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", identity, "--keychain", keychain, "--timestamp=none", app.path])
        }
        func descriptor(_ release: MCPComponentRelease) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(release)) as! [String: Any]
            for name in ["url", "size", "sha256"] { object.removeValue(forKey: name) }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func package(_ kind: MCPComponentKind, version: String, minimumMCP: String? = nil, bad: Bool = false) async throws -> MCPComponentRelease {
            let name = kind == .mcp ? "QueryCraftMCP" : "QueryCraftSkill"
            let working = root.appending(path: "fixtures/" + kind.rawValue + version)
            let payload = working.appending(path: name)
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            if kind == .mcp {
                let app = payload.appending(path: "QueryCraft MCP.app")
                try fm.copyItem(at: source, to: app)
                let infoURL = app.appending(path: "Contents/Info.plist")
                var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
                info["CFBundleShortVersionString"] = version; info["QCMCPVersion"] = version
                info["CFBundleVersion"] = "1"; info["QCComponentPublicKey"] = key.publicKey.rawRepresentation.base64EncodedString()
                info["QCComponentCatalogBaseURL"] = baseURL.absoluteString
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
                if bad {
                    let c = working.appending(path: "bad.c")
                    try Data("#include <string.h>\n#include <stdio.h>\nint main(int argc,char **argv){if(argc>1&&!strcmp(argv[1],\"--version\")){puts(\"\(version)\");return 0;}return 42;}\n".utf8).write(to: c)
                    _ = try await MCPProcess.run(URL(fileURLWithPath: "/usr/bin/cc"), arguments: [c.path, "-o", app.appending(path: "Contents/MacOS/querycraft-mcp").path])
                }
                try await sign(app)
            } else {
                let skill = payload.appending(path: "querycraft")
                try fm.createDirectory(at: skill, withIntermediateDirectories: true)
                try Data("# Fixture Skill \(version)\n".utf8).write(to: skill.appending(path: "SKILL.md"))
            }
            let archiveName = "\(kind.rawValue)-\(version).zip"
            var release = MCPComponentRelease(component: kind, version: version, build: "1", architectures: [kind == .skill ? "any" : DatabaseDriverArchitecture.current.rawValue],
                minimumAppVersion: "0.1.9", maximumAppVersionExclusive: nil, driverAPI: 5, storageAPI: 1, credentialAPI: 1, desktopAPI: 1,
                minimumMCPVersion: minimumMCP, maximumMCPVersionExclusive: kind == .skill ? "1.0.0" : nil,
                sha256: String(repeating: "0", count: 64), size: 1, url: baseURL.appending(path: archiveName))
            try descriptor(release).write(to: payload.appending(path: "component.json"))
            let archive = serving.appending(path: archiveName)
            _ = try await MCPProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", payload.path, archive.path], timeout: 120)
            release = .init(component: release.component, version: release.version, build: release.build, architectures: release.architectures,
                minimumAppVersion: release.minimumAppVersion, maximumAppVersionExclusive: nil, driverAPI: 5, storageAPI: 1, credentialAPI: 1, desktopAPI: 1,
                minimumMCPVersion: minimumMCP, maximumMCPVersionExclusive: release.maximumMCPVersionExclusive,
                sha256: try MCPComponentCatalog.sha256(archive), size: (try fm.attributesOfItem(atPath: archive.path)[.size] as! NSNumber).int64Value,
                url: release.url)
            return release
        }
        func publish(_ kind: MCPComponentKind, _ releases: [MCPComponentRelease], corrupt: Bool = false) throws {
            let records = try releases.map { release -> MCPComponentCatalog.Envelope in
                let payload = try JSONEncoder().encode(release)
                return .init(payload: payload, signature: corrupt ? Data(repeating: 0, count: 64) : try key.signature(for: payload))
            }
            let file = kind == .mcp ? "mcp-\(DatabaseDriverArchitecture.current.rawValue).json" : "skill.json"
            try JSONEncoder().encode(MCPComponentCatalog.Catalog(schemaVersion: 1, component: kind, releases: records))
                .write(to: serving.appending(path: file), options: .atomic)
        }
        let v1 = try await package(.mcp, version: "0.1.0")
        let v2 = try await package(.mcp, version: "0.1.1")
        let broken = try await package(.mcp, version: "0.1.2", bad: true)
        let skill1 = try await package(.skill, version: "1.0.0", minimumMCP: "0.1.0")
        let skill2 = try await package(.skill, version: "1.0.1", minimumMCP: "0.1.1")
        try publish(.mcp, [v1]); try publish(.skill, [skill2, skill1])
        let legacy = root.appending(path: "MCP/QueryCraft MCP.app")
        try fm.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: legacy)
        let legacyInfo = try Data(contentsOf: legacy.appending(path: "Contents/Info.plist"))
        var policy = MCPPolicy(); policy.enabled = true
        policy.http.port = Int(ProcessInfo.processInfo.environment["QC_MCP_COMPONENT_HTTP_PORT"]!)!
        let store = MCPPolicyStore(directory: root); try store.save(policy)
        let policyData = try Data(contentsOf: root.appending(path: "mcp-policy.json"))
        try await installation.install()
        try check(try await installation.installedVersion() == "0.1.0", "independent runtime install failed")
        let launcher = await installation.executableURL
        try check(launcher.path.hasSuffix("/bin/querycraft-mcp"), "runtime did not install a stable launcher")
        try check(try await MCPProcess.run(launcher, arguments: ["--version"]) == "0.1.0", "stable launcher did not exec active version")
        let skill = MCPSkillInstallation(catalog: catalog, host: host, cache: root.appending(path: "SkillPackages"))
        let destination = root.appending(path: "SkillHome/querycraft")
        try await skill.install(at: destination, mcpVersion: "0.1.0")
        try check(await skill.installedVersion(at: destination) == "1.0.0", "skill did not select compatible fallback")
        print("PASS signed catalog download, metadata/ZIP checks, independent runtime/skill install, MCP compatibility fallback and stable launcher")

        let oldRuntime = await installation.appURL
        let old = Process(); old.executableURL = oldRuntime.appending(path: "Contents/MacOS/querycraft-mcp")
        old.arguments = ["--stdio", "--data-dir", root.path]
        let input = Pipe(); old.standardInput = input
        let log = root.appending(path: "old-session.jsonl"); fm.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log); old.standardOutput = output; old.standardError = FileHandle.nullDevice
        try old.run()
        defer { if old.isRunning { old.terminate() }; try? output.close(); try? input.fileHandleForWriting.close() }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "ComponentCheck", "version": "1"]]])
        func waitForResponse(_ id: Int) async throws {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                let lines = (try? Data(contentsOf: log))?.split(separator: 10) ?? []
                if lines.contains(where: { ((try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any])?["id"] as? Int == id }) { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw CheckFailure(message: "old runtime did not answer request \(id)")
        }
        try await waitForResponse(1)
        let service = MCPServiceManager(directory: root)
        try await service.start(executable: launcher.path, settings: policy.http)
        try publish(.mcp, [v2, v1])
        _ = try await MCPProcess.run(launcher, arguments: ["--update", "--data-dir", root.path], timeout: 120)
        try check(try await MCPProcess.run(launcher, arguments: ["--version"]) == "0.1.1", "standalone CLI update did not activate v2")
        var request = URLRequest(url: URL(string: policy.http.endpoint)!)
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("Bearer " + policy.http.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"UpdateCheck\",\"version\":\"1\"}}}".utf8)
        let (responseData, response) = try await URLSession.shared.data(for: request)
        try check((response as? HTTPURLResponse)?.statusCode == 200 && !responseData.isEmpty,
                  "updated HTTP initialize failed: status \((response as? HTTPURLResponse)?.statusCode ?? -1), bytes \(responseData.count)")
        let responseText = String(decoding: responseData, as: UTF8.self)
        try responseData.write(to: serving.deletingLastPathComponent().appending(path: "updated-http-response.txt"))
        let messages = responseText.split(separator: "\n").filter { $0.hasPrefix("data:") }
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any] }
        let object = messages.first(where: { $0["result"] != nil })
            ?? (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = object?["result"] as? [String: Any]
        try check((response as? HTTPURLResponse)?.statusCode == 200 && (result?["serverInfo"] as? [String: Any])?["version"] as? String == "0.1.1",
                  "standalone update did not restart HTTP on v2 with the saved token")
        try await service.stop()
        print("PASS independent CLI update stops/restarts live launchd HTTP with saved settings and authenticates the new version")
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "querycraft_list_connections", "arguments": [:]]])
        try await waitForResponse(2)
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(15)
        while old.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(!old.isRunning && old.terminationStatus == 0, "old session could not complete after update")
        let responses = try Data(contentsOf: log).split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        try check(responses.contains { ($0["id"] as? Int) == 2 && $0["error"] == nil && $0["result"] != nil }, "old session tool call failed after update")
        try check(fm.fileExists(atPath: oldRuntime.appending(path: "Contents/Resources").path), "update removed old session resources")
        try check(try Data(contentsOf: legacy.appending(path: "Contents/Info.plist")) == legacyInfo, "legacy client runtime was modified")
        try check(try Data(contentsOf: root.appending(path: "mcp-policy.json")) == policyData, "component update rewrote authorization")
        print("PASS standalone CLI update without desktop, new connections use v2, existing v1 stdio session completes a real MCP tool call; legacy path and authorization preserved")

        try publish(.mcp, [broken, v2, v1])
        do { try await installation.install(); throw CheckFailure(message: "broken self-test was accepted") } catch is MCPFailure {}
        try check(try await installation.installedVersion() == "0.1.1", "failed self-test changed active runtime")
        try publish(.mcp, [v1])
        do { try await installation.install(); throw CheckFailure(message: "automatic downgrade was accepted") } catch is MCPFailure {}
        try publish(.mcp, [v2], corrupt: true)
        do { try await installation.install(); throw CheckFailure(message: "forged catalog accepted") } catch is MCPFailure {}
        try publish(.mcp, [v2, v1])
        do {
            let lock = try MCPComponentLock(directory: root.appending(path: "MCP"))
            defer { withExtendedLifetime(lock) {} }
            do { _ = try await MCPProcess.run(launcher, arguments: ["--update", "--data-dir", root.path]); throw CheckFailure(message: "concurrent CLI update accepted") } catch is MCPFailure {}
        }
        _ = try await MCPProcess.run(launcher, arguments: ["--update-skill", "--skill-destination", destination.path, "--data-dir", root.path], timeout: 120)
        try check(await skill.installedVersion(at: destination) == "1.0.1", "independent skill upgrade failed")
        let entry = destination.appending(path: "SKILL.md"), original = try Data(contentsOf: destination.appending(path: "SKILL.md"))
        try Data("local workflow".utf8).write(to: entry)
        do { try await skill.install(at: destination, mcpVersion: "0.1.1"); throw CheckFailure(message: "modified skill was overwritten") } catch is MCPFailure {}
        do { try await skill.uninstall(at: destination); throw CheckFailure(message: "modified skill was removed") } catch is MCPFailure {}
        try check(try String(contentsOf: entry, encoding: .utf8) == "local workflow", "local skill edits were lost")
        try original.write(to: entry)
        _ = try await MCPProcess.run(launcher, arguments: ["--rollback", "--data-dir", root.path])
        try check(try await MCPProcess.run(launcher, arguments: ["--version"]) == "0.1.0", "explicit rollback failed")
        _ = try await MCPProcess.run(launcher, arguments: ["--update-skill", "--skill-destination", destination.path, "--data-dir", root.path], timeout: 120)
        try check(await skill.installedVersion(at: destination) == "1.0.0", "Skill did not restore compatibility after MCP rollback")
        try await skill.uninstall(at: destination)
        try await installation.uninstall()
        try check(try Data(contentsOf: root.appending(path: "mcp-policy.json")) == policyData, "uninstall removed authorization")
        print("PASS self-test failure recovery, signature rejection, downgrade refusal, cross-process lock, explicit rollback, independent skill update/local-edit protection and uninstall-preserves-policy")
    }
}
