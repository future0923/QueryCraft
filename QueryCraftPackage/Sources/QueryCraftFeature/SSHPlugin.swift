import Foundation
import Darwin
import Synchronization
import CQueryCraftSSHPluginAPI
import CryptoKit
import Security

struct SSHJumpRequest: Sendable {
    let connection: SSHConnection
    let secret: String?
    let agentSocket: String?
}

struct SSHRequest: Sendable {
    let connection: SSHConnection
    let secret: String?
    let command: String?
    let timeoutMilliseconds: Int
    let maximumOutputBytes: Int
    var jumps: [SSHJumpRequest] = []
    var agentSocket: String? = nil
    var scanHostKey = false
}

struct SSHResult: Sendable {
    var status: Int32 = 0
    var exitStatus: Int32 = -1
    var commandMayHaveRun = false
    var truncated = false
    var stdout = Data()
    var stderr = Data()
    var outputBytes: UInt64 = 0
    var diagnostic: SSHDiagnostic? = nil

    var value: MCPJSONValue {
        .object(["status": .string(exitStatus < 0 ? "connected" : "completed"), "exit_code": exitStatus < 0 ? .null : .int(Int(exitStatus)),
                 "stdout": .string(String(decoding: stdout, as: UTF8.self)), "stderr": .string(String(decoding: stderr, as: UTF8.self)),
                 "truncated": .bool(truncated), "output_bytes": .int(Int(clamping: outputBytes)), "automatic_retry": false])
    }

    func validate() throws {
        guard status != 0 else { return }
        let detail = commandMayHaveRun ? " The command or target file may have changed; check its outcome before repeating the operation." : ""
        let (message, code): (String, MCPFailureCode) = switch Int(status) {
        case QC_SSH_HOST_KEY: ("SSH host fingerprint does not match. Verify it with the server administrator.", .accessDenied)
        case QC_SSH_AGENT: ("Local SSH agent is unavailable, empty or returned an invalid response. Check its socket and loaded identities.", .credentialUnavailable)
        case QC_SSH_AUTH: ("SSH authentication failed. Check the saved credential or private key.", .credentialUnavailable)
        case QC_SSH_TIMEOUT: ("SSH operation timed out.", .timeout)
        case QC_SSH_CANCELLED: ("SSH operation was cancelled.", .cancelled)
        case QC_SSH_CAPACITY: ("SSH connection or resolver capacity reached.", .capacity)
        case QC_SSH_NOT_FOUND: ("Remote file or directory was not found.", .invalidArgument)
        case QC_SSH_PERMISSION: ("The SSH account cannot access this remote path.", .accessDenied)
        case QC_SSH_EXISTS: ("The destination already exists. Confirm replacement explicitly before enabling overwrite.", .invalidArgument)
        case QC_SSH_UNSUPPORTED: ("The SSH server or plugin does not support this SFTP operation.", .unsupported)
        case QC_SSH_LIMIT: ("The file operation exceeded its byte or entry limit.", .capacity)
        case QC_SSH_CHANGED: ("The source file changed during transfer. The destination was preserved.", .invalidArgument)
        case QC_SSH_LOCAL_IO: ("The local path must be an accessible regular file with an existing parent directory. Symlink inputs are not accepted.", .invalidArgument)
        default: ("SSH connection or operation failed. Check the server and plugin.", commandMayHaveRun ? .outcomeUnknown : .driverFailure)
        }
        throw MCPFailure(message + (diagnostic.map { " " + $0.message } ?? "") + detail, code: code,
                         details: diagnostic.map { .object(["ssh": $0.value]) })
    }
}

protocol SSHTransport: Sendable {
    var runtimeInfo: SSHPluginRuntimeInfo? { get }
    var supportsFiles: Bool { get }
    var supportsFileManagement: Bool { get }
    var supportsTransferProgress: Bool { get }
    var supportsRoutes: Bool { get }
    func execute(_ request: SSHRequest) async throws -> SSHResult
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult
    func invalidate(connectionID: UUID?) async
    func pruneIdleConnections() async
}
extension SSHTransport {
    var runtimeInfo: SSHPluginRuntimeInfo? { nil }
    var supportsFiles: Bool { false }
    var supportsFileManagement: Bool { false }
    var supportsTransferProgress: Bool { false }
    var supportsRoutes: Bool { false }
    func invalidate(connectionID: UUID?) async {}
    func pruneIdleConnections() async {}
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult {
        throw MCPFailure("Install an SSH plugin with SFTP extension 1 and reconnect the MCP client.", code: .unsupported)
    }
}

/// The plugin owns libssh2/OpenSSL. Host code shares only the versioned C ABI.
final class SSHPlugin: SSHTransport, Sendable {
    private typealias Version = @Sendable @convention(c) () -> UInt32
    private typealias Create = @Sendable @convention(c) (UnsafePointer<qc_ssh_request>?) -> OpaquePointer?
    private typealias FileCreate = @Sendable @convention(c) (UnsafePointer<qc_ssh_file_request>?) -> OpaquePointer?
    private typealias Run = @Sendable @convention(c) (OpaquePointer?) -> UnsafePointer<qc_ssh_result>?
    private typealias Control = @Sendable @convention(c) (OpaquePointer?) -> Void
    private typealias PoolCreate = @Sendable @convention(c) (UInt32, UInt32, UInt32) -> OpaquePointer?
    private typealias PoolRun = @Sendable @convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<CChar>?) -> UnsafePointer<qc_ssh_result>?
    private typealias PoolInvalidate = @Sendable @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    private typealias SetProgress = @Sendable @convention(c) (OpaquePointer?, qc_ssh_progress_callback?, UnsafeMutableRawPointer?) -> Void
    private typealias SetRoute = @Sendable @convention(c) (OpaquePointer?, UnsafePointer<qc_ssh_route_options>?) -> Int32
    private typealias Diagnostic = @Sendable @convention(c) (OpaquePointer?) -> UnsafePointer<qc_ssh_diagnostic>?
    private struct PoolFunctions: Sendable {
        let create: PoolCreate
        let run: PoolRun
        let invalidate: PoolInvalidate
        let prune: Control
        let destroy: Control
    }
    private struct Functions: Sendable {
        let create: Create
        let fileCreate: FileCreate?
        let managesFiles: Bool
        let run: Run
        let cancel: Control
        let destroy: Control
        let pool: PoolFunctions?
        let setProgress: SetProgress?
        let setRoute: SetRoute?
        let diagnostic: Diagnostic?
    }
    private static let libraries = Mutex<[String: Functions]>([:])
    private let functions: Functions
    private let pool: Pool?
    let runtimeInfo: SSHPluginRuntimeInfo?

    static func bundleURL(in directory: URL) -> URL {
        directory.appending(path: "Plugins/SSH/Current/QueryCraftSSH.bundle", directoryHint: .isDirectory)
    }

    init(bundleURL: URL) throws {
        let bundleURL = bundleURL.resolvingSymlinksInPath()
        // Use the same signature policy as external database plugins; verify
        // before dlopen, including every nested code resource and architecture.
        try Self.verifySignature(at: bundleURL)
        guard let bundle = Bundle(url: bundleURL),
              bundle.bundleIdentifier == "io.github.future0923.QueryCraft.SSH",
              bundle.object(forInfoDictionaryKey: "QCSSHPluginABIVersion") as? Int == 1,
              let executable = bundle.executableURL else {
            throw MCPFailure("SSH plugin is missing, invalid or incompatible. Install a compatible signed plugin.", code: .unsupported)
        }
        functions = try Self.libraries.withLock { libraries in
            if let loaded = libraries[bundleURL.path] { return loaded }
            guard let handle = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL) else {
                throw MCPFailure("Cannot load this SSH plugin architecture or its dependencies.", code: .unsupported)
            }
            do {
                func symbol<T>(_ name: String, _: T.Type) throws -> T {
                    guard let pointer = dlsym(handle, name) else { throw MCPFailure("SSH plugin ABI is incomplete.", code: .unsupported) }
                    return unsafeBitCast(pointer, to: T.self)
                }
                let version = try symbol("querycraft_ssh_plugin_version", Version.self)
                guard version() == QC_SSH_ABI_VERSION else { throw MCPFailure("SSH plugin ABI is incompatible.", code: .unsupported) }
                let fileVersion = dlsym(handle, "querycraft_ssh_plugin_file_version").map { unsafeBitCast($0, to: Version.self) }
                let fileCreate: FileCreate? = (fileVersion?() ?? 0) == UInt32(QC_SSH_FILE_ABI_VERSION)
                    ? dlsym(handle, "querycraft_ssh_plugin_file_create").map { unsafeBitCast($0, to: FileCreate.self) } : nil
                let managementVersion = dlsym(handle, "querycraft_ssh_plugin_file_management_version").map { unsafeBitCast($0, to: Version.self) }
                let poolVersion = dlsym(handle, "querycraft_ssh_plugin_pool_version").map { unsafeBitCast($0, to: Version.self) }
                let pooling: PoolFunctions? = (poolVersion?() ?? 0) == 1 ? try PoolFunctions(
                    create: symbol("querycraft_ssh_plugin_pool_create", PoolCreate.self),
                    run: symbol("querycraft_ssh_plugin_pool_run", PoolRun.self),
                    invalidate: symbol("querycraft_ssh_plugin_pool_invalidate", PoolInvalidate.self),
                    prune: symbol("querycraft_ssh_plugin_pool_prune", Control.self),
                    destroy: symbol("querycraft_ssh_plugin_pool_destroy", Control.self)) : nil
                let progressVersion = dlsym(handle, "querycraft_ssh_plugin_progress_version").map { unsafeBitCast($0, to: Version.self) }
                let setProgress: SetProgress? = (progressVersion?() ?? 0) == 1
                    ? dlsym(handle, "querycraft_ssh_plugin_set_progress").map { unsafeBitCast($0, to: SetProgress.self) } : nil
                let routeVersion = dlsym(handle, "querycraft_ssh_plugin_route_version").map { unsafeBitCast($0, to: Version.self) }
                let setRoute: SetRoute? = (routeVersion?() ?? 0) == 1
                    ? dlsym(handle, "querycraft_ssh_plugin_set_route").map { unsafeBitCast($0, to: SetRoute.self) } : nil
                let diagnosticVersion = dlsym(handle, "querycraft_ssh_plugin_diagnostic_version").map { unsafeBitCast($0, to: Version.self) }
                let diagnostic: Diagnostic? = (diagnosticVersion?() ?? 0) == 1
                    ? dlsym(handle, "querycraft_ssh_plugin_diagnostic").map { unsafeBitCast($0, to: Diagnostic.self) } : nil
                let functions = try Functions(create: symbol("querycraft_ssh_plugin_create", Create.self), fileCreate: fileCreate, managesFiles: fileCreate != nil && (managementVersion?() ?? 0) == 1,
                    run: symbol("querycraft_ssh_plugin_run", Run.self), cancel: symbol("querycraft_ssh_plugin_cancel", Control.self),
                    destroy: symbol("querycraft_ssh_plugin_destroy", Control.self), pool: pooling, setProgress: setProgress, setRoute: setRoute,
                    diagnostic: diagnostic)
                // Keep successful modules resident until process exit. A
                // cancelled system resolver can finish after its request;
                // unloading its code earlier would leave a live thread in it.
                libraries[bundleURL.path] = functions
                return functions
            } catch { dlclose(handle); throw error }
        }
        pool = try functions.pool.map { try Pool(functions: $0) }
        runtimeInfo = SSHPluginRuntimeInfo(bundle: .read(at: bundleURL),
            files: functions.fileCreate != nil, management: functions.managesFiles, pooling: functions.pool != nil,
            progress: functions.setProgress != nil, routes: functions.setRoute != nil, diagnostics: functions.diagnostic != nil)
    }

    static func verifySignature(at url: URL) throws {
        // QueryCraft's free distribution uses a pinned self-signed certificate,
        // which has no Apple Team ID. Accept the host's exact leaf certificate;
        // otherwise retain the existing Apple-team / Debug ad-hoc rules.
        var host: SecStaticCode?, plugin: SecStaticCode?, information: CFDictionary?
        if SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, SecCSFlags(), &host) == errSecSuccess,
           let host, SecCodeCopySigningInformation(host, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first,
           SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &plugin) == errSecSuccess, let plugin {
            let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
            var requirement: SecRequirement?
            let text = "identifier \"io.github.future0923.QueryCraft.SSH\" and certificate leaf = H\"\(digest)\""
            if SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
               SecStaticCodeCheckValidity(plugin, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess {
                return
            }
        }
        try DatabaseDriverPackageInstaller.verifySignature(at: url)
    }

    func execute(_ request: SSHRequest) async throws -> SSHResult {
        try await executeOperation(request, file: nil)
    }
    var supportsFiles: Bool { functions.fileCreate != nil }
    var supportsFileManagement: Bool { functions.managesFiles }
    var supportsTransferProgress: Bool { functions.setProgress != nil }
    var supportsRoutes: Bool { functions.setRoute != nil }
    var supportsConnectionReuse: Bool { pool != nil }
    func invalidate(connectionID: UUID?) async {
        guard let pool else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { pool.invalidate(connectionID); continuation.resume() }
        }
    }
    func pruneIdleConnections() async {
        guard let pool else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { pool.prune(); continuation.resume() }
        }
    }
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult {
        try file.validate()
        guard supportsFiles else { throw MCPFailure("Reconnect using an SSH plugin with SFTP extension 1.", code: .unsupported) }
        return try await executeOperation(request, file: file)
    }
    private func executeOperation(_ request: SSHRequest, file: SSHFileRequest?) async throws -> SSHResult {
        try Task.checkCancellation()
        try request.connection.validate()
        guard (1...300_000).contains(request.timeoutMilliseconds), (1...1_048_576).contains(request.maximumOutputBytes),
              request.secret.map({ !$0.contains("\0") && $0.utf8.count <= 65_536 }) ?? true,
              request.command.map({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 65_536 }) ?? true else {
            throw MCPFailure("Invalid SSH command, credential or execution limits.")
        }
        guard request.jumps.count <= 4 else { throw MCPFailure("SSH jump chain exceeds four hops.") }
        for jump in request.jumps {
            try jump.connection.validate()
            guard (jump.agentSocket != nil) == (jump.connection.authenticationMethod == .agent) else {
                throw MCPFailure("Jump authentication does not match its saved account.", code: .invalidArgument)
            }
        }
        guard request.scanHostKey || ((request.agentSocket != nil) == (request.connection.authenticationMethod == .agent)) else {
            throw MCPFailure("SSH authentication does not match its saved account.", code: .invalidArgument)
        }
        if !request.scanHostKey && request.connection.authenticationMethod == .agent && request.agentSocket == nil {
            throw MCPFailure("SSH_AUTH_SOCK is unavailable. Set the agent socket in the saved connection.", code: .credentialUnavailable)
        }
        if request.connection.authenticationMethod == .agent || !request.jumps.isEmpty || request.scanHostKey {
            guard supportsRoutes else { throw MCPFailure("Install SSH 0.6.0 or later and reconnect for agent/jump-host connections.", code: .unsupported) }
        }
        let operation = try makeOperation(request, file: file)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // C nonblocking socket/poll code runs on a dedicated worker,
                // never on the main actor or Swift's cooperative executor.
                DispatchQueue.global(qos: .utility).async { [self] in
                    let result = operation.run()
                    withExtendedLifetime(self) { continuation.resume(returning: result) }
                }
            }
        } onCancel: { operation.cancel() }
    }

    private func makeOperation(_ request: SSHRequest, file: SSHFileRequest?) throws -> Operation {
        let profile = request.connection
        let values: [String?] = [profile.host, profile.username, profile.hostFingerprint, profile.privateKeyPath, request.secret, request.command,
                                 file?.remotePath, file?.localPath, file?.temporaryPath]
        // create copies its inputs before these temporary C strings are freed.
        let strings = values.map { $0.flatMap { strdup($0) } }
        defer { for (index, pointer) in strings.enumerated() { if let pointer { if index == 4 { qc_ssh_wipe(pointer, strlen(pointer)) }; free(pointer) } } }
        guard zip(values, strings).allSatisfy({ $0.0 == nil || $0.1 != nil }) else { throw MCPFailure("Cannot allocate SSH request.", code: .capacity) }
        var raw = qc_ssh_request()
        raw.size = UInt32(MemoryLayout<qc_ssh_request>.size)
        raw.host = strings[0].map { UnsafePointer($0) }; raw.port = UInt16(profile.port)
        raw.username = strings[1].map { UnsafePointer($0) }; raw.host_fingerprint = strings[2].map { UnsafePointer($0) }
        raw.private_key_path = strings[3].map { UnsafePointer($0) }; raw.secret = strings[4].map { UnsafePointer($0) }
        raw.command = strings[5].map { UnsafePointer($0) }; raw.timeout_ms = UInt32(request.timeoutMilliseconds)
        raw.maximum_output_bytes = UInt32(request.maximumOutputBytes)
        let task: OpaquePointer?
        if let file, let create = functions.fileCreate {
            var value = qc_ssh_file_request()
            value.size = UInt32(MemoryLayout<qc_ssh_file_request>.size); value.connection = raw
            value.operation = file.operation.rawValue
            value.remote_path = strings[6].map { UnsafePointer($0) }; value.local_path = strings[7].map { UnsafePointer($0) }
            value.temporary_path = strings[8].map { UnsafePointer($0) }
            value.offset = UInt64(file.offset); value.maximum_transfer_bytes = UInt64(file.maximumTransferBytes)
            value.maximum_entries = UInt32(file.maximumEntries); value.overwrite = file.overwrite ? 1 : 0
            task = create(&value)
        } else { task = functions.create(&raw) }
        guard let task else { throw MCPFailure("SSH plugin rejected the request.", code: .unsupported) }
        do { try configureRoute(task, request: request) }
        catch { functions.destroy(task); throw error }
        return Operation(task: task, functions: functions, pool: request.jumps.isEmpty && request.agentSocket == nil && !request.scanHostKey ? pool : nil, scope: profile.id.uuidString, progress: file?.progress,
                         endpoints: request.jumps.map(\.connection) + [profile])
    }

    private func configureRoute(_ task: OpaquePointer, request: SSHRequest) throws {
        guard !request.jumps.isEmpty || request.agentSocket != nil || request.scanHostKey else { return }
        guard let configure = functions.setRoute else { throw MCPFailure("Upgrade SSH to 0.6.0.", code: .unsupported) }
        var allocated: [UnsafeMutablePointer<CChar>] = []
        var secrets: [UnsafeMutablePointer<CChar>] = []
        defer {
            for pointer in secrets { qc_ssh_wipe(pointer, strlen(pointer)) }
            for pointer in allocated { free(pointer) }
        }
        func string(_ value: String?, secret: Bool = false) throws -> UnsafePointer<CChar>? {
            guard let value else { return nil }
            guard !value.contains("\0"), value.utf8.count <= 65_536, let pointer = strdup(value) else { throw MCPFailure("Invalid SSH route value.") }
            allocated.append(pointer); if secret { secrets.append(pointer) }; return UnsafePointer(pointer)
        }
        var hops: [qc_ssh_hop] = []
        for jump in request.jumps {
            var hop = qc_ssh_hop(), raw = qc_ssh_request()
            raw.size = UInt32(MemoryLayout<qc_ssh_request>.size)
            raw.host = try string(jump.connection.host); raw.port = UInt16(jump.connection.port)
            raw.username = try string(jump.connection.username); raw.host_fingerprint = try string(jump.connection.hostFingerprint)
            raw.private_key_path = try string(jump.connection.privateKeyPath); raw.secret = try string(jump.secret, secret: true)
            raw.timeout_ms = UInt32(request.timeoutMilliseconds); raw.maximum_output_bytes = UInt32(request.maximumOutputBytes)
            hop.size = UInt32(MemoryLayout<qc_ssh_hop>.size); hop.connection = raw; hop.agent_socket = try string(jump.agentSocket)
            hops.append(hop)
        }
        var options = qc_ssh_route_options()
        options.size = UInt32(MemoryLayout<qc_ssh_route_options>.size); options.agent_socket = try string(request.agentSocket)
        options.hop_count = UInt32(hops.count); options.scan_host_key = request.scanHostKey ? 1 : 0
        let status = hops.withUnsafeBufferPointer { buffer in options.hops = buffer.baseAddress; return configure(task, &options) }
        guard status == 0 else { throw MCPFailure("SSH plugin rejected the jump/agent configuration.", code: .unsupported) }
    }

    // C serializes pool metadata with its mutex and leases each session to one
    // worker. Operations/controls retain this wrapper until all C calls finish;
    // only then may deinit destroy it. No libssh2 handle crosses this boundary.
    private final class Pool: @unchecked Sendable {
        let pointer: OpaquePointer
        let functions: PoolFunctions
        init(functions: PoolFunctions) throws {
            guard let pointer = functions.create(8, 60_000, 300_000) else { throw MCPFailure("Cannot allocate SSH connection pool.", code: .capacity) }
            self.pointer = pointer; self.functions = functions
        }
        deinit { functions.destroy(pointer) }
        func run(_ task: OpaquePointer, scope: String) -> UnsafePointer<qc_ssh_result>? {
            scope.withCString { functions.run(pointer, task, $0) }
        }
        func invalidate(_ id: UUID?) {
            if let id { id.uuidString.withCString { functions.invalidate(pointer, $0) } }
            else { functions.invalidate(pointer, nil) }
        }
        func prune() { functions.prune(pointer) }
    }

    private final class ProgressSink: Sendable {
        let receive: @Sendable (SSHTransferProgress) -> Void
        init(_ receive: @escaping @Sendable (SSHTransferProgress) -> Void) { self.receive = receive }
    }

    // C owns this allocation. NSLock protects every access to its lifetime;
    // the worker alone runs it, and the only concurrent C operation is an
    // atomic cancellation flag. This is the locked C-interop Sendable boundary.
    private final class Operation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: OpaquePointer?
        private let functions: Functions
        private let pool: Pool?
        private let scope: String
        // Retained until run/destroy finish; C only borrows this context.
        private let progress: ProgressSink?
        private let endpoints: [SSHConnection]
        init(task: OpaquePointer, functions: Functions, pool: Pool?, scope: String, progress: (@Sendable (SSHTransferProgress) -> Void)?, endpoints: [SSHConnection]) {
            self.task = task; self.functions = functions; self.pool = pool; self.scope = scope
            self.endpoints = endpoints
            self.progress = progress.map(ProgressSink.init)
            if let sink = self.progress, let set = functions.setProgress {
                set(task, { context, value in
                    guard let context, let raw = value?.pointee, raw.size == MemoryLayout<qc_ssh_progress>.size,
                          let phase = SSHTransferProgress.Phase(rawValue: raw.phase) else { return }
                    Unmanaged<ProgressSink>.fromOpaque(context).takeUnretainedValue().receive(.init(phase: phase,
                        transferred: raw.transferred, total: raw.total_known != 0 ? raw.total : nil))
                }, Unmanaged.passUnretained(sink).toOpaque())
            }
        }
        func cancel() { lock.withLock { if let task { functions.cancel(task) } } }
        func run() -> SSHResult {
            // Only this worker runs libssh2. Concurrent cancellation touches
            // the plugin's atomic flag; destroy is serialized with cancel.
            let pointer = lock.withLock { task! }
            var result: SSHResult
            let response: UnsafePointer<qc_ssh_result>?
            if let pool { response = pool.run(pointer, scope: scope) }
            else { response = functions.run(pointer) }
            if let raw = response?.pointee, raw.size == MemoryLayout<qc_ssh_result>.size {
                result = SSHResult(status: raw.status, exitStatus: raw.exit_status, commandMayHaveRun: raw.command_may_have_run != 0,
                    truncated: raw.truncated != 0,
                    stdout: raw.stdout_data.map { Data(bytes: $0, count: raw.stdout_length) } ?? Data(),
                    stderr: raw.stderr_data.map { Data(bytes: $0, count: raw.stderr_length) } ?? Data(), outputBytes: raw.output_bytes)
            } else { result = SSHResult(status: Int32(QC_SSH_IO), commandMayHaveRun: true) }
            if let raw = functions.diagnostic?(pointer)?.pointee { result.diagnostic = SSHDiagnostic(raw, endpoints: endpoints) }
            lock.withLock { if let task { functions.destroy(task); self.task = nil } }
            return result
        }
    }
}
