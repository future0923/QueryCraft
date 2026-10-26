import Foundation
import Darwin

struct SSHConfigEndpoint: Equatable, Sendable {
    let alias: String
    let host: String
    let port: Int
    let username: String
    func matches(_ profile: SSHConnection) -> Bool {
        host.caseInsensitiveCompare(profile.host) == .orderedSame && port == profile.port && username == profile.username
    }
}
struct SSHConfigCandidate: Identifiable, Sendable {
    var id: String { endpoint.alias }
    let endpoint: SSHConfigEndpoint
    let authentication: SSHAuthentication
    let keyPath: String?
    let agentSocketPath: String?
    let jumps: [SSHConfigEndpoint]
    let warnings: [String]
    let blocked: Bool
    func jumpID(in profiles: [SSHConnection]) throws -> UUID? {
        var previous: UUID?
        for endpoint in jumps {
            let matches = profiles.filter { endpoint.matches($0) && $0.jumpConnectionID == previous }
            let named = matches.filter { $0.name == endpoint.alias }
            let candidates = named.isEmpty ? matches : named
            guard candidates.count == 1, let profile = candidates.first else {
                throw MCPFailure(AppCopy.current.text("请先保存并配置跳板机 \(endpoint.alias)，再重新读取预览；同一跳板机不能有歧义。", "Save and configure jump host \(endpoint.alias), then reload the preview. Its saved account must be unambiguous."))
            }
            previous = profile.id
        }
        return previous
    }
}
struct SSHConfigPreview: Sendable {
    let candidates: [SSHConfigCandidate]
    let warnings: [String]
}

/// Connection-only, bounded OpenSSH import. Never invokes ssh -G, a shell,
/// Match exec, ProxyCommand or any LocalCommand from configuration content.
struct SSHConfigImporter: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var username = NSUserName()
    var environment = ProcessInfo.processInfo.environment
    private struct Statement { let key: String; let values: [String]; let source: String; let line: Int }
    func preview(path: String) throws -> SSHConfigPreview {
        var statements: [Statement] = [], stack: Set<String> = [], total = 0, files = 0, warnings: [String] = []
        var global = true
        try read(URL(fileURLWithPath: expandHome(path)), depth: 0, stack: &stack, bytes: &total, files: &files,
            global: &global, statements: &statements, warnings: &warnings)
        var aliases: [String] = [], seen: Set<String> = []
        for row in statements where row.key == "host" {
            for alias in row.values where !alias.hasPrefix("!") && !alias.contains("*") && !alias.contains("?") {
                if seen.insert(alias.lowercased()).inserted { aliases.append(alias) }
            }
        }
        guard aliases.count <= 256 else { throw MCPFailure("SSH config contains more than 256 concrete aliases.") }
        let hasMatch = statements.contains { $0.key == "match" }
        if hasMatch { warnings.append("Match sections require manual configuration; no Match command was executed.") }
        let candidates = aliases.map { alias -> SSHConfigCandidate in
            do {
                let fields = fields(for: alias, statements: statements)
                let endpoint = try endpoint(alias, fields: fields)
                var notes: [String] = [], blocked = hasMatch || !warnings.isEmpty
                if let proxy = fields["proxycommand"]?.joined(separator: " "), proxy.lowercased() != "none" {
                    notes.append("ProxyCommand is unsupported and was not executed."); blocked = true
                }
                if fields["localcommand"] != nil || fields["remotecommand"] != nil {
                    notes.append("LocalCommand/RemoteCommand are not imported or executed.")
                }
                if let canonical = fields["canonicalizehostname"]?.first, !["no", "false"].contains(canonical.lowercased()) {
                    notes.append("Hostname canonicalization is unsupported; configure this connection manually."); blocked = true
                }
                let identities = fields["identityfile"] ?? []
                if identities.count > 1 { notes.append("Multiple IdentityFile entries: preview uses the first; review the key before saving.") }
                let key = try identities.first.flatMap { $0.lowercased() == "none" ? nil : try expand($0, endpoint: endpoint) }
                let agent = fields["identityagent"]?.first
                let noAgent = agent?.lowercased() == "none"
                let socket = try agent.flatMap { value -> String? in
                    if ["none", "SSH_AUTH_SOCK", "$SSH_AUTH_SOCK"].contains(value) { return nil }
                    return try expand(value, endpoint: endpoint)
                }
                let preferred = fields["preferredauthentications"]?.first?.split(separator: ",").map(String.init) ?? []
                let publicKeys = fields["pubkeyauthentication"]?.first?.lowercased() != "no"
                let passwordOnly = preferred == ["password"] || !publicKeys
                if !preferred.isEmpty && !preferred.contains("password") && !preferred.contains("publickey") {
                    notes.append("This authentication method is unsupported; configure manually."); blocked = true
                }
                let auth: SSHAuthentication = passwordOnly ? .password : key != nil ? .privateKey : noAgent ? .password : .agent
                if auth == .agent && fields["identitiesonly"]?.first?.lowercased() == "yes" {
                    notes.append("IdentitiesOnly without an explicit private key cannot be honored by agent import."); blocked = true
                }
                let restricted = ["certificatefile", "pkcs11provider", "securitykeyprovider", "bindaddress", "bindinterface", "addressfamily", "hostkeyalgorithms", "kexalgorithms", "ciphers", "macs"]
                if restricted.contains(where: { fields[$0] != nil }) {
                    notes.append("Additional identity, source-address or algorithm restrictions require manual review."); blocked = true
                }
                if fields["forwardagent"] != nil { notes.append("Agent forwarding is never enabled by this import.") }
                let jumps = try jumpChain(fields["proxyjump"]?.first, statements: statements, seen: [alias.lowercased()])
                guard jumps.count <= 4 else { throw MCPFailure("ProxyJump exceeds four hops.") }
                return SSHConfigCandidate(endpoint: endpoint, authentication: auth, keyPath: auth == .privateKey ? key : nil,
                    agentSocketPath: auth == .agent ? socket : nil, jumps: jumps, warnings: notes, blocked: blocked)
            } catch {
                let message = (error as? MCPFailure)?.message ?? "Cannot resolve this SSH alias. Configure it manually."
                return SSHConfigCandidate(endpoint: .init(alias: alias, host: alias, port: 22, username: username), authentication: .password,
                    keyPath: nil, agentSocketPath: nil, jumps: [], warnings: [message], blocked: true)
            }
        }
        return .init(candidates: candidates, warnings: warnings)
    }
    private func fields(for alias: String, statements: [Statement]) -> [String: [String]] {
        var active = true, result: [String: [String]] = [:]
        for row in statements {
            if row.key == "host" { active = Self.matches(alias, patterns: row.values); continue }
            if row.key == "match" { active = false; continue }
            guard active else { continue }
            if row.key == "identityfile" { result[row.key, default: []].append(contentsOf: row.values) }
            else if result[row.key] == nil { result[row.key] = row.values }
        }
        return result
    }
    private func endpoint(_ alias: String, fields: [String: [String]], overrideUser: String? = nil, overridePort: Int? = nil) throws -> SSHConfigEndpoint {
        let host = (fields["hostname"]?.first ?? alias).replacingOccurrences(of: "%h", with: alias).replacingOccurrences(of: "%n", with: alias)
        let port: Int
        if let overridePort { port = overridePort }
        else if let text = fields["port"]?.first { guard let value = Int(text) else { throw MCPFailure("Invalid SSH Port.") }; port = value }
        else { port = 22 }
        let user = overrideUser ?? fields["user"]?.first ?? username
        guard !host.isEmpty, host.utf8.count <= 253, !host.contains(where: { $0.isWhitespace || $0 == "\0" || $0 == "%" }),
              !user.isEmpty, user.utf8.count <= 256, !user.contains("\0"), (1...65535).contains(port) else { throw MCPFailure("Invalid HostName, User or Port.") }
        return .init(alias: alias, host: host, port: port, username: user)
    }
    private func jumpChain(_ value: String?, statements: [Statement], seen: Set<String>) throws -> [SSHConfigEndpoint] {
        guard let value, value.lowercased() != "none" else { return [] }
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(tokens.count), tokens.allSatisfy({ !$0.isEmpty }), seen.count <= 5 else { throw MCPFailure("Invalid or excessive ProxyJump chain.") }
        var result: [SSHConfigEndpoint] = [], visited = seen
        for token in tokens {
            var host = token, user: String?, port: Int?
            if let at = host.lastIndex(of: "@") { user = String(host[..<at]); host = String(host[host.index(after: at)...]) }
            if host.hasPrefix("[") {
                guard let end = host.firstIndex(of: "]") else { throw MCPFailure("Invalid bracketed ProxyJump host.") }
                let trailing = String(host[host.index(after: end)...]); host = String(host[host.index(after: host.startIndex)..<end])
                if !trailing.isEmpty { guard trailing.hasPrefix(":"), let number = Int(trailing.dropFirst()) else { throw MCPFailure("Invalid ProxyJump port.") }; port = number }
            } else if host.filter({ $0 == ":" }).count == 1, let end = host.lastIndex(of: ":") {
                guard let number = Int(host[host.index(after: end)...]) else { throw MCPFailure("Invalid ProxyJump port.") }
                port = number; host = String(host[..<end])
            }
            guard visited.insert(host.lowercased()).inserted else { throw MCPFailure("ProxyJump contains a cycle.") }
            let config = fields(for: host, statements: statements)
            if let command = config["proxycommand"]?.joined(separator: " "), command.lowercased() != "none" { throw MCPFailure("Jump host uses unsupported ProxyCommand; nothing was executed.") }
            if let nested = config["proxyjump"]?.first, nested.lowercased() != "none" {
                guard tokens.count == 1 else { throw MCPFailure("Mixed explicit and nested ProxyJump chains require manual review.") }
                result += try jumpChain(nested, statements: statements, seen: visited)
            }
            result.append(try endpoint(host, fields: config, overrideUser: user, overridePort: port))
            guard result.count <= 4 else { throw MCPFailure("ProxyJump exceeds four hops.") }
        }
        return result
    }
    private func expandHome(_ value: String) -> String {
        value == "~" ? home.path : value.hasPrefix("~/") ? home.appending(path: String(value.dropFirst(2))).path : value
    }
    private func expand(_ value: String, endpoint: SSHConfigEndpoint) throws -> String {
        var result = "", index = value.startIndex
        let tokens: [Character: String] = ["h": endpoint.host, "n": endpoint.alias, "p": String(endpoint.port), "r": endpoint.username,
            "u": username, "d": home.path, "%": "%"]
        while index < value.endIndex {
            let character = value[index]; index = value.index(after: index)
            if character == "%" {
                guard index < value.endIndex, let replacement = tokens[value[index]] else { throw MCPFailure("Unsupported SSH path token; configure the path manually.") }
                result += replacement; index = value.index(after: index)
            } else if character == "$", index < value.endIndex, value[index] == "{" {
                guard let end = value[index...].firstIndex(of: "}") else { throw MCPFailure("Invalid SSH environment token.") }
                let key = String(value[value.index(after: index)..<end])
                guard let replacement = environment[key] else { throw MCPFailure("An SSH path environment variable is unavailable.") }
                result += replacement; index = value.index(after: end)
            } else { result.append(character) }
        }
        result = expandHome(result)
        guard result.hasPrefix("/"), !result.contains("\0"), result.utf8.count <= 4096 else { throw MCPFailure("SSH paths must resolve to an absolute local path.") }
        return result
    }
    private func read(_ url: URL, depth: Int, stack: inout Set<String>, bytes: inout Int, files: inout Int,
                      global: inout Bool, statements: inout [Statement], warnings: inout [String]) throws {
        guard depth <= 16, files < 128 else { throw MCPFailure("SSH Include depth/file limit exceeded.") }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard stack.insert(canonical).inserted else { throw MCPFailure("SSH Include contains a cycle.") }
        defer { stack.remove(canonical) }; files += 1
        let fd = Darwin.open(canonical, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { throw MCPFailure("Cannot read the selected SSH configuration.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 1_048_576 - bytes else { throw MCPFailure("SSH configuration must be regular UTF-8 files, at most 1 MiB total.") }
        let data = try file.read(upToCount: 1_048_577 - bytes) ?? Data(); bytes += data.count
        guard bytes <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw MCPFailure("SSH configuration is too large or not UTF-8.") }
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var values = try Self.tokenize(String(line)); guard !values.isEmpty else { continue }
            var key = values.removeFirst()
            if let equals = key.firstIndex(of: "=") { let initial = String(key[key.index(after: equals)...]); key = String(key[..<equals]); if !initial.isEmpty { values.insert(initial, at: 0) } }
            if values.first == "=" { values.removeFirst() }
            else if let first = values.first, first.hasPrefix("=") { values[0] = String(first.dropFirst()) }
            key = key.lowercased()
            guard !values.isEmpty, line.utf8.count <= 16_384, statements.count < 16_384 else { throw MCPFailure("Invalid or excessive SSH configuration directives.") }
            if ["hostname", "port", "user", "proxyjump", "identityagent", "identityfile"].contains(key), values.count != 1 {
                throw MCPFailure("An SSH connection directive requires exactly one quoted or unquoted argument.")
            }
            if key == "include" {
                guard global else { warnings.append("Conditional Include requires manual configuration; it was not evaluated."); continue }
                for pattern in values {
                    let expanded = expandHome(pattern)
                    let path = expanded.hasPrefix("/") ? expanded : home.appending(path: ".ssh/" + expanded).path
                    var matches = glob_t()
                    let status = path.withCString { Darwin.glob($0, GLOB_LIMIT, nil, &matches) }
                    defer { globfree(&matches) }
                    guard status == 0 || status == GLOB_NOMATCH, matches.gl_pathc <= 128 else { throw MCPFailure("Invalid or excessive SSH Include expansion.") }
                    if status == 0, let paths = matches.gl_pathv {
                        for index in 0..<matches.gl_pathc {
                            guard let entry = paths[index] else { continue }
                            try read(URL(fileURLWithPath: String(cString: entry)), depth: depth + 1, stack: &stack, bytes: &bytes,
                                files: &files, global: &global, statements: &statements, warnings: &warnings)
                            // Include files restore their caller's global context.
                            global = true
                            statements.append(.init(key: "host", values: ["*"], source: url.lastPathComponent, line: number + 1))
                        }
                    }
                }
                continue
            }
            if key == "host" || key == "match" { global = false }
            statements.append(.init(key: key, values: values, source: url.lastPathComponent, line: number + 1))
        }
    }
    static func matches(_ alias: String, patterns: [String]) -> Bool {
        var positive = false
        for pattern in patterns {
            let negative = pattern.hasPrefix("!")
            if wildcard(negative ? String(pattern.dropFirst()) : pattern, text: alias) {
                if negative { return false }; positive = true
            }
        }
        return positive
    }
    private static func wildcard(_ pattern: String, text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var i = 0, j = 0, star: Int?, retry = 0
        while j < t.count {
            if i < p.count && (p[i] == "?" || p[i] == t[j]) { i += 1; j += 1 }
            else if i < p.count && p[i] == "*" { star = i; i += 1; retry = j }
            else if let star { i = star + 1; retry += 1; j = retry }
            else { return false }
        }
        while i < p.count && p[i] == "*" { i += 1 }
        return i == p.count
    }
    private static func tokenize(_ line: String) throws -> [String] {
        var result: [String] = [], token = "", quote: Character?, escaped = false, began = false
        for char in line {
            if escaped { token.append(char); escaped = false; began = true; continue }
            if char == "\\" { escaped = true; began = true; continue }
            if let current = quote { if char == current { quote = nil } else { token.append(char) }; continue }
            if char == "\"" || char == "'" { quote = char; began = true }
            else if char == "#" { break }
            else if char.isWhitespace { if began { result.append(token); token = ""; began = false } }
            else { token.append(char); began = true }
        }
        guard quote == nil, !escaped else { throw MCPFailure("Unclosed SSH config quote or escape.") }
        if began { result.append(token) }; return result
    }
}
