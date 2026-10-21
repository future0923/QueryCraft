import AppKit
import Foundation
import Observation

@MainActor @Observable
final class MCPSettingsModel {
    var policy = MCPPolicy()
    var historyRows: [MCPCallRecord] = []
    var historyLoaded = false
    var historyLoading = false
    var historyError: String?
    var skillTarget: MCPSkillTarget = .shared
    var skillStatus: MCPSkillInstallation.Status?
    var skillError: String?
    private let skillInstaller: MCPSkillInstallation
    var installedSkillVersion: String?
    var availableSkillVersion: String?
    var componentError: String?
    var checkingComponents = false
    @ObservationIgnored private var componentTask: Task<Void, Never>?
    private let skillHomeDirectory: URL
    var serverIdentity: MCPServerIdentity { MCPServerIdentity(directory: directory) }
    var skillDirectory: URL { skillTarget.directory(in: skillHomeDirectory, identity: serverIdentity) }
    private let historyStore: MCPHistoryStore
    var profiles: [ConnectionProfile] = []
    var groups: [ConnectionGroup] = []
    var installedVersion: String?
    var availableVersion: String?
    var runtimeUpdateAvailable: Bool {
        guard let installedVersion, let availableVersion else { return false }
        return availableVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }
    var executable = ""
    var error: String?
    var status = ""
    var isBusy = false
    var installationProgress: MCPComponentInstallationProgress?
    var isLoading = false
    var isCheckingRuntime = false
    var runtimeStatusLoaded = false
    var runtimeError: String?
    var didLoad = false
    var httpRunning = false
    var search = ""
    var databaseChoices: [UUID: [String]] = [:]
    var databaseChoiceErrors: [UUID: String] = [:]
    var loadingDatabaseChoices: Set<UUID> = []
    var databaseSearch = ""
    var connectionPage = 0
    var connectionPageSize = 6
    var allowedPage = 0
    var rulePage = 0
    var databasePage = 0
    var selectedConnection: UUID?
    var client = MCPClientConfiguration.clients[0]
    var clientRegistration: MCPClientRegistration.Inspection?
    var clientRegistrationError: String?
    var clientRegistrationChecking = false
    private let clientRegistrar: MCPClientRegistration
    private var clientInspectionID = UUID()
    private var clientInspectionKey = ""
    var transport = "stdio"
    var section = "access"
    var authorizationStep = "connections"
    var connectionFilterVisible = false
    var scopeEditorConnection: ConnectionProfile?
    var showsHTTPSettings = false
    var databaseNameDrafts: [UUID: String] = [:]
    var databaseSearches: [UUID: String] = [:]
    var lastRestrictedMode: MCPExecutionMode = .readOnly
    var settingsScrollTarget: String?
    var settingsNavigationRevision = 0
    private let store: MCPPolicyStore
    private let directory: URL
    private let installation: MCPInstallation
    private let service: MCPServiceManager
    private let settingsLoader: @Sendable () async throws -> MCPSettingsSnapshot
    private let checksRemoteComponents: Bool
    private let runtimeChecker: @Sendable () async throws -> MCPSettingsRuntimeStatus
    private let databaseDiscoverer: (@Sendable (ConnectionProfile) async throws -> [String])?
    @ObservationIgnored private var databaseDiscoveryRequests: [UUID: UUID] = [:]
    @ObservationIgnored private var activationTask: Task<Void, Never>?
    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory,
         installation: MCPInstallation = .shared, service: MCPServiceManager = .shared,
         skillHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         clientRegistrar: MCPClientRegistration? = nil,
         skillInstaller: MCPSkillInstallation? = nil,
         settingsLoader: (@Sendable () async throws -> MCPSettingsSnapshot)? = nil,
         runtimeChecker: (@Sendable () async throws -> MCPSettingsRuntimeStatus)? = nil,
         databaseDiscoverer: (@Sendable (ConnectionProfile) async throws -> [String])? = nil) {
        self.databaseDiscoverer = databaseDiscoverer
        self.checksRemoteComponents = runtimeChecker == nil
        self.skillInstaller = skillInstaller ?? MCPSkillInstallation(cache: directory.appending(path: "SkillPackages"))
        self.directory = directory; self.installation = installation; self.service = service
        self.skillHomeDirectory = skillHomeDirectory
        self.clientRegistrar = clientRegistrar ?? MCPClientRegistration(identity: MCPServerIdentity(directory: directory))
        store = MCPPolicyStore(directory: directory)
        historyStore = MCPHistoryStore(directory: directory)
        let loader = MCPSettingsLoader(directory: directory)
        self.settingsLoader = settingsLoader ?? { try await loader.load() }
        self.runtimeChecker = runtimeChecker ?? {
            async let installed = installation.installedVersion()
            async let running = service.isRunning()
            return try await MCPSettingsRuntimeStatus(installedVersion: installed, availableVersion: nil, httpRunning: running)
        }
    }
    var filteredProfiles: [ConnectionProfile] {
        profiles.filter { search.isEmpty || "\($0.name) \($0.host) \($0.databaseType.rawValue) \($0.defaultDatabase ?? "") \($0.id)".localizedCaseInsensitiveContains(search) }
    }
    var authorizedProfiles: [ConnectionProfile] { profiles.filter { policy.includesConnection($0) } }
    var availableProfiles: [ConnectionProfile] { filteredProfiles.filter { !policy.includesConnection($0) } }
    var allowedProfiles: [ConnectionProfile] { filteredProfiles.filter { policy.includesConnection($0) } }
    func removeConnection(_ profile: ConnectionProfile) {
        guard policy.includesConnection(profile) else { return }
        // Materialize current grants, but keep unrelated groups' future-member grants intact.
        policy.connectionIDs.formUnion(authorizedProfiles.map(\.id))
        policy.allConnections = false
        if let groupID = profile.groupID { policy.groupIDs.remove(groupID) }
        policy.connectionIDs.remove(profile.id)
    }
    func captureQueryTimeout() {
        policy.inheritedQueryTimeoutSeconds = ApplicationPreferences.shared.queryTimeout.duration.map { Int($0.components.seconds) } ?? 0
    }
    var configuration: String {
        MCPClientConfiguration.make(client: client, executable: executable,
            dataDirectory: directory.path, http: transport == "http" ? policy.http : nil)
    }
    func inspectClientRegistration() async {
        let client = client, configuration = configuration
        let requestID = UUID(); clientInspectionID = requestID
        let key = client + configuration
        if clientInspectionKey != key { clientRegistration = nil; clientInspectionKey = key }
        clientRegistrationError = nil; clientRegistrationChecking = false
        guard MCPClientRegistration.supports(client) else { return }
        clientRegistrationChecking = true
        defer { if clientInspectionID == requestID { clientRegistrationChecking = false } }
        do {
            let result = try await clientRegistrar.inspect(client: client, configuration: configuration)
            guard clientInspectionID == requestID, self.client == client && self.configuration == configuration else { return }
            clientRegistration = result
        } catch {
            guard clientInspectionID == requestID, self.client == client && self.configuration == configuration else { return }
            clientRegistrationError = error.localizedDescription
        }
    }
    func changeClientRegistration(adding: Bool) async {
        guard didLoad, !isBusy, !adding || installedVersion != nil else { return }
        isBusy = true; defer { isBusy = false }
        let client = client, configuration = configuration
        do {
            let backup = try await clientRegistrar.change(client: client, configuration: configuration, adding: adding)
            error = nil
            status = adding
                ? AppCopy.current.text("已添加到 \(client)，请重新连接 MCP 或重启客户端。", "Added to \(client). Reconnect MCP or restart the client.")
                : AppCopy.current.text("已从 \(client) 移除 QueryCraft MCP。", "QueryCraft MCP removed from \(client).")
            if let backup { status += AppCopy.current.text(" 备份：", " Backup: ") + backup.path }
            await inspectClientRegistration()
        } catch {
            clientRegistrationError = error.localizedDescription
        }
    }
    /// This short-lived model-owned task survives sidebar navigation, avoiding cancelled/restarted
    /// signature and version checks. The settings window owns the model and the task clears itself.
    func activate() async {
        guard !didLoad || !runtimeStatusLoaded else { return }
        if activationTask == nil {
            activationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.activationTask = nil }
                if self.didLoad { await self.checkRuntimeStatus() }
                else { await self.load() }
            }
        }
        await activationTask?.value
    }
    func load() async {
        guard !didLoad, !isLoading, !isBusy else { return }
        isLoading = true
        do {
            async let loaded = settingsLoader()
            async let path = installation.executableURL.path
            let (snapshot, executable) = try await (loaded, path)
            try Task.checkCancellation()
            policy = snapshot.policy; profiles = snapshot.connections.profiles; groups = snapshot.connections.groups
            if policy.mode != .fullAccess { lastRestrictedMode = policy.mode }
            self.executable = executable
            didLoad = true; error = nil
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
        isLoading = false
        if didLoad { await checkRuntimeStatus() }
    }
    private func checkRuntimeStatus() async {
        guard !isCheckingRuntime else { return }
        isCheckingRuntime = true; defer { isCheckingRuntime = false }
        do {
            let result = try await runtimeChecker()
            try Task.checkCancellation()
            installedVersion = result.installedVersion; availableVersion = result.availableVersion
            httpRunning = result.httpRunning; runtimeStatusLoaded = true; runtimeError = nil
            scheduleComponentCheck()
        } catch is CancellationError {
        } catch { runtimeError = error.localizedDescription; runtimeStatusLoaded = true }
    }
    private func scheduleComponentCheck() {
        guard checksRemoteComponents, componentTask == nil else { return }
        componentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.componentTask = nil }
            await self.checkComponentUpdates()
        }
    }
    func checkComponentUpdates() async {
        guard !checkingComponents else { return }; checkingComponents = true; defer { checkingComponents = false }
        var failures: [String] = []
        do { availableVersion = try await installation.availableVersion() }
        catch is CancellationError { return }
        catch { failures.append("MCP: " + error.localizedDescription) }
        if let installedVersion {
            do { availableSkillVersion = try await skillInstaller.checkForUpdates(mcpVersion: installedVersion) }
            catch is CancellationError { return }
            catch { failures.append("Skill: " + error.localizedDescription) }
        }
        await inspectSkill()
        componentError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
    func recheck() async {
        guard didLoad else { await load(); return }
        guard !isBusy, !isCheckingRuntime else { return }; isBusy = true; defer { isBusy = false }
        do {
            async let refreshed = settingsLoader()
            await checkRuntimeStatus()
            let snapshot = try await refreshed
            // Refresh the connection catalog without replacing unsaved authorization edits.
            let refreshedProfiles = snapshot.connections.profiles
            let oldProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            let currentProfiles = Dictionary(uniqueKeysWithValues: refreshedProfiles.map { ($0.id, $0) })
            let cachedIDs = Set(databaseChoices.keys).union(databaseChoiceErrors.keys).union(loadingDatabaseChoices)
            for id in cachedIDs where oldProfiles[id] != currentProfiles[id] {
                databaseChoices[id] = nil
                databaseChoiceErrors[id] = nil
                databaseDiscoveryRequests[id] = nil
                loadingDatabaseChoices.remove(id)
            }
            profiles = refreshedProfiles; groups = snapshot.connections.groups
            await inspectSkill()
            await inspectClientRegistration()
            if section == "activity" { await loadHistory() }
            if runtimeError == nil {
                error = nil
                status = AppCopy.current.text("已重新检查运行状态，未保存的设置已保留", "Runtime checked; unsaved settings preserved")
            }
        } catch { self.error = error.localizedDescription }
    }
    func updateOptimizations(_ update: (inout MCPOptimizationSettings) -> Void) {
        var options = policy.tuning; update(&options); policy.optimizations = options
    }
    func loadHistory() async {
        guard !historyLoading else { return }; historyLoading = true; defer { historyLoading = false }
        do { historyRows = try await historyStore.recent(); historyLoaded = true; historyError = nil }
        catch { historyError = error.localizedDescription }
    }
    func clearHistory() async {
        guard !historyLoading else { return }; historyLoading = true; defer { historyLoading = false }
        do { try await historyStore.clear(); historyRows = []; historyLoaded = true; historyError = nil }
        catch { historyError = error.localizedDescription }
    }
    func inspectSkill() async {
        let target = skillTarget
        do {
            let state = try await skillInstaller.status(at: target.directory(in: skillHomeDirectory, identity: serverIdentity))
            guard skillTarget == target else { return }
            skillStatus = state; installedSkillVersion = await skillInstaller.installedVersion(at: target.directory(in: skillHomeDirectory, identity: serverIdentity)); skillError = nil
        } catch { if skillTarget == target { skillError = error.localizedDescription; skillStatus = nil } }
    }
    func changeSkillInstallation(install: Bool) async {
        guard !isBusy else { return }; isBusy = true
        defer { isBusy = false; installationProgress = nil }
        error = nil; skillError = nil; status = ""
        let target = skillTarget
        do {
            if install {
                installationProgress = .init(phase: .checking)
                try await skillInstaller.install(at: target.directory(in: skillHomeDirectory, identity: serverIdentity), mcpVersion: installedVersion) { [weak self] progress in
                    await self?.updateInstallationProgress(progress)
                }
            }
            else { try await skillInstaller.uninstall(at: target.directory(in: skillHomeDirectory, identity: serverIdentity)) }
            await inspectSkill()
            status = AppCopy.current.text("Skill 已更新，重新打开客户端后生效", "Skill updated; reopen your client to load it")
        } catch { skillError = error.localizedDescription }
    }
    func save() {
        guard didLoad else { return }
        do { captureQueryTimeout(); try store.save(policy); error = nil; status = AppCopy.current.text("已保存；权限立即生效，HTTP 监听地址变更需重启服务", "Saved; permissions apply immediately. Restart HTTP to apply listening address changes.") }
        catch { self.error = error.localizedDescription }
    }
    func install() async {
        guard !isBusy, !isCheckingRuntime else { return }; isBusy = true
        defer { isBusy = false; installationProgress = nil }
        error = nil; runtimeError = nil; status = ""
        installationProgress = .init(phase: .checking)
        do {
            let restartHTTP = await service.isRunning()
            // Updates restart the configuration the service was actually running.
            // Unsaved editor values must not redirect its readiness check.
            let runningHTTP = restartHTTP ? try store.load().http : policy.http
            if restartHTTP { try await service.stop(); httpRunning = false }
            do {
                try await installation.install { [weak self] progress in
                    await self?.updateInstallationProgress(progress)
                }
                installationProgress = .init(phase: .finishing)
                if restartHTTP { try await service.start(executable: executable, settings: runningHTTP); httpRunning = true }
            } catch {
                if restartHTTP { try? await service.start(executable: executable, settings: runningHTTP) }
                httpRunning = await service.isRunning()
                throw error
            }
            installedVersion = try await installation.installedVersion()
            executable = await installation.executableURL.path
            error = nil; runtimeError = nil; runtimeStatusLoaded = true
            status = AppCopy.current.text("安装完成，协议自检通过；请重新添加旧客户端配置以使用固定启动入口。", "Installed; MCP self-check passed. Update legacy client entries to use the stable launcher.")
            // Optional catalog checks can be slow; installation is already complete.
            availableVersion = installedVersion
            scheduleComponentCheck()
        } catch { self.error = error.localizedDescription }
    }
    private func updateInstallationProgress(_ progress: MCPComponentInstallationProgress) {
        installationProgress = progress
    }
    func authorizeCredentials() async {
        guard didLoad, !isBusy else { return }; isBusy = true; defer { isBusy = false }
        do {
            captureQueryTimeout(); try store.save(policy)
            error = nil
            status = AppCopy.current.text("正在统一授权已选连接…", "Authorizing selected connections…")
            let supported = try? await MCPProcess.run(URL(fileURLWithPath: executable), arguments: ["--credential-protocol"])
            guard supported == "2",
                  Bundle.main.object(forInfoDictionaryKey: "QCSharedCredentialHelperRequired") as? Bool == true else {
                throw MCPFailure(AppCopy.current.text("请升级主程序和 MCP 程序后使用统一凭据授权。", "Update QueryCraft and the MCP runtime to use shared credential authorization."), code: .unsupported)
            }
            let repository = SQLiteConnectionProfileRepository(databaseURL: directory.appending(path: "QueryCraft.sqlite"))
            let count = try await MCPCredentialAuthorization.authorize(profiles: try await repository.fetchAll(), policy: policy,
                source: KeychainCredentialStore(directory: directory, allowsInteraction: false), destination: SharedKeychainCredentialStore(directory: directory),
                legacy: LegacyKeychainCredentialStore(allowsInteraction: false))
            status = AppCopy.current.text("已统一授权 \(count) 个连接的凭据", "Authorized credentials for \(count) connections"); error = nil
        } catch {
            let failure = MCPFailure.normalized(error)
            self.error = failure.code == .credentialDenied
                ? AppCopy.current.text("无法静默读取旧凭据。请先解锁登录钥匙串，并在 QueryCraft 中确认该连接可正常连接后重试；不会逐条弹出授权。",
                    "Cannot read legacy credentials without prompting. Unlock the login Keychain and verify the connection in QueryCraft, then retry.")
                : failure.localizedDescription
        }
    }
    func uninstall() async {
        guard !isBusy, !isCheckingRuntime else { return }; isBusy = true; defer { isBusy = false }
        do {
            try await service.stop()
            try await installation.uninstall()
            installedVersion = nil; httpRunning = false; error = nil; runtimeError = nil; runtimeStatusLoaded = true
        } catch { httpRunning = await service.isRunning(); self.error = error.localizedDescription }
    }
    func setHTTPRunning(_ running: Bool) async {
        guard didLoad, !isBusy else { return }; isBusy = true; defer { isBusy = false }
        do {
            // Stopping must remain possible even when the editor contains invalid values.
            if running {
                captureQueryTimeout(); try store.save(policy)
                try await service.start(executable: executable, settings: policy.http)
            }
            else { try await service.stop() }
            httpRunning = await service.isRunning(); error = nil
            status = running ? AppCopy.current.text("HTTP 服务已启动", "HTTP service started")
                : AppCopy.current.text("HTTP 服务已停止，未保存的设置已保留", "HTTP service stopped; unsaved settings preserved")
        } catch { httpRunning = await service.isRunning(); self.error = error.localizedDescription }
    }
    func copyConfiguration() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(configuration, forType: .string) }
    func discoverDatabases(for id: UUID) async {
        guard !loadingDatabaseChoices.contains(id), let profile = profiles.first(where: { $0.id == id }) else { return }
        let requestID = UUID()
        databaseDiscoveryRequests[id] = requestID
        loadingDatabaseChoices.insert(id)
        defer {
            if databaseDiscoveryRequests[id] == requestID {
                loadingDatabaseChoices.remove(id)
                databaseDiscoveryRequests[id] = nil
            }
        }
        do {
            let choices: [String]
            if let databaseDiscoverer { choices = try await databaseDiscoverer(profile) }
            else { choices = try await fetchDatabaseChoices(profile) }
            try Task.checkCancellation()
            guard databaseDiscoveryRequests[id] == requestID, profiles.first(where: { $0.id == id }) == profile else { return }
            databaseChoices[id] = Array(Set(choices)).sorted()
            databaseChoiceErrors[id] = nil
        } catch {
            if !(error is CancellationError), databaseDiscoveryRequests[id] == requestID,
               profiles.first(where: { $0.id == id }) == profile {
                databaseChoiceErrors[id] = error.localizedDescription
            }
        }
    }
    private func fetchDatabaseChoices(_ profile: ConnectionProfile) async throws -> [String] {
        let runtime = MCPRuntime(directory: directory, credentials: KeychainCredentialStore(directory: directory))
        do {
            let session = try await runtime.connect(profile, database: profile.defaultDatabase, mode: .readOnly)
            do {
                let choices: [String]
                if [.kafka, .elasticsearch].contains(profile.databaseType) {
                    choices = try await session.fetchObjects(in: profile.defaultDatabase ?? (profile.databaseType == .kafka ? "Kafka" : "")).map(\.name)
                } else { choices = try await session.fetchDatabases() }
                try Task.checkCancellation()
                await session.close()
                await runtime.shutdown()
                return choices
            } catch { await session.close(); throw error }
        } catch {
            await runtime.shutdown()
            throw error
        }
    }
    func rule(for id: UUID) -> MCPConnectionPolicy { policy.connections[id.uuidString] ?? .init() }
    func updateRule(for id: UUID, _ update: (inout MCPConnectionPolicy) -> Void) {
        var rule = rule(for: id); update(&rule); policy.connections[id.uuidString] = rule
    }
}

actor MCPServiceManager {
    static let shared = MCPServiceManager()
    private let directory: URL
    private let label: String
    private let agentsDirectory: URL
    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory,
         agentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")) {
        self.directory = directory
        self.agentsDirectory = agentsDirectory
        self.label = "io.github.future0923.QueryCraft.MCP." + directory.lastPathComponent
    }
    private var domain: String { "gui/\(getuid())" }
    private var plist: URL { agentsDirectory.appending(path: "\(label).plist") }
    func isRunning() async -> Bool {
        (try? await MCPProcess.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["print", "\(domain)/\(label)"]))?.contains("state = running") == true
    }
    func start(executable: String, settings: MCPHTTPSettings) async throws {
        try settings.validate()
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw MCPFailure("Install MCP before starting HTTP.") }
        if FileManager.default.fileExists(atPath: plist.path) { try await stop() }
        let log = directory.appending(path: "MCP/http.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration: [String: Any] = ["Label": label, "ProgramArguments": [executable, "--http", "--data-dir", directory.path],
            "RunAtLoad": true, "StandardErrorPath": log.path, "StandardOutPath": "/dev/null", "Umask": 0o077]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0).write(to: plist, options: .atomic)
        _ = try await MCPProcess.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["bootstrap", domain, plist.path])
        // Verify the endpoint rather than reporting success merely because launchd accepted a job.
        var request = URLRequest(url: URL(string: settings.endpoint)!)
        request.httpMethod = "POST"; request.timeoutInterval = 2
        request.setValue("Bearer " + settings.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"QueryCraft Check\",\"version\":\"1\"}}}".utf8)
        // A cold signed process can spend several seconds in macOS launch validation.
        // Count elapsed time, not quick connection-refused responses (previously only ~3 seconds).
        let deadline = Date().addingTimeInterval(20)
        repeat {
            if let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse, http.statusCode == 200 {
                if let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
                    var cleanup = request; cleanup.httpMethod = "DELETE"; cleanup.httpBody = nil
                    cleanup.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
                    cleanup.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
                    _ = try? await URLSession.shared.data(for: cleanup)
                }
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        try? await stop()
        throw MCPFailure("HTTP did not pass its readiness check. Check the address, port and MCP/http.log.")
    }
    func stop() async throws {
        if await isRunning() { _ = try await MCPProcess.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["bootout", "\(domain)/\(label)"]) }
        else { _ = try? await MCPProcess.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["bootout", "\(domain)/\(label)"]) }
        if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
    }
}
