import AppKit

@MainActor
final class WorkspaceWindowManager: NSObject {
    static let shared = WorkspaceWindowManager(
        restorationRepository: SQLiteWorkspaceRestorationRepository()
    )

    private var groups: [UUID: WorkspaceWindowGroup] = [:]
    private weak var welcomeWindow: NSWindow?
    private let restorationRepository: any WorkspaceRestorationRepository
    private let profileRepository: any ConnectionProfileRepository
    private let credentialStore: any CredentialStore
    private let credentialPrompter: any WorkspaceCredentialPrompting
    private var restorationAttempt:
        (id: UUID, task: Task<Void, Error>)?
    private var workspaceOpenAttempts: [
        ConnectionProfile.ID: (id: UUID, task: Task<Bool, Error>)
    ] = [:]
    private var closeAllTask: Task<Bool, Never>?
    private var databaseMoveTasks: [UUID: Task<Void, Never>] = [:]

    init(
        restorationRepository: any WorkspaceRestorationRepository,
        profileRepository: any ConnectionProfileRepository =
            SQLiteConnectionProfileRepository(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        credentialPrompter: any WorkspaceCredentialPrompting =
            NativeWorkspaceCredentialPrompter()
    ) {
        self.restorationRepository = restorationRepository
        self.profileRepository = profileRepository
        self.credentialStore = credentialStore
        self.credentialPrompter = credentialPrompter
        super.init()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @discardableResult
    func openWorkspace(
        profileID: ConnectionProfile.ID,
        welcomeWindow: NSWindow?
    ) async throws -> Bool {
        if let welcomeWindow {
            self.welcomeWindow = welcomeWindow
        }

        let didOpen = try await openWorkspace(
            profileID: profileID,
            attachedTo: welcomeWindow
        )
        if didOpen {
            welcomeWindow?.orderOut(nil)
        }
        return didOpen
    }

    @discardableResult
    func openWorkspace(
        profileID: ConnectionProfile.ID,
        attachedTo presentingWindow: NSWindow?
    ) async throws -> Bool {

        if let existingGroup = groups.values.first(where: {
            $0.model.profileID == profileID
        }) {
            existingGroup.open()
            return true
        }

        if let attempt = workspaceOpenAttempts[profileID] {
            return try await attempt.task.value
        }

        let attemptID = UUID()
        let task = Task<Bool, Error> { @MainActor [weak self] in
            guard let self else { return false }
            return try await self.prepareAndOpenWorkspace(
                profileID: profileID,
                attachedTo: presentingWindow
            )
        }
        workspaceOpenAttempts[profileID] = (attemptID, task)
        do {
            let didOpen = try await task.value
            if workspaceOpenAttempts[profileID]?.id == attemptID {
                workspaceOpenAttempts[profileID] = nil
            }
            return didOpen
        } catch {
            if workspaceOpenAttempts[profileID]?.id == attemptID {
                workspaceOpenAttempts[profileID] = nil
            }
            throw error
        }
    }

    private func prepareAndOpenWorkspace(
        profileID: ConnectionProfile.ID,
        attachedTo presentingWindow: NSWindow?
    ) async throws -> Bool {
        if let existingGroup = groups.values.first(where: {
            $0.model.profileID == profileID
        }) {
            existingGroup.open()
            return true
        }

        guard let password = try await resolvePassword(
            profileID: profileID,
            attachedTo: presentingWindow
        ) else {
            return false
        }

        if let existingGroup = groups.values.first(where: {
            $0.model.profileID == profileID
        }) {
            existingGroup.open()
            return true
        }

        let group = WorkspaceWindowGroup(
            profileID: profileID,
            workspacePassword: password,
            restorationRepository: restorationRepository,
            workspaceManager: self,
            didClose: { [weak self] workspaceID in
                self?.workspaceDidClose(workspaceID)
            },
            didRequestMoveDatabaseContext: { [weak self] group, contextID in
                self?.moveDatabaseContextToNewWindow(
                    from: group,
                    contextID: contextID
                )
            }
        )
        groups[group.model.workspaceID] = group
        group.open()
        return true
    }

    func fetchConnectionProfiles() async throws -> [ConnectionProfile] {
        if ProcessInfo.processInfo.environment["QUERYCRAFT_UI_TESTING"] == "1" {
            return QueryCraftUITestFixtures.profiles
        }
        return try await profileRepository.fetchAll()
    }

    func restoreWorkspaces(welcomeWindow: NSWindow?) async throws {
        if let welcomeWindow {
            self.welcomeWindow = welcomeWindow
        }

        let attempt: (id: UUID, task: Task<Void, Error>)
        if let restorationAttempt {
            attempt = restorationAttempt
        } else {
            let attemptID = UUID()
            let task = Task<Void, Error> { @MainActor [weak self] in
                guard let self else { return }
                try await self.performWorkspaceRestoration()
            }
            attempt = (attemptID, task)
            restorationAttempt = attempt
        }

        do {
            try await attempt.task.value
        } catch {
            if restorationAttempt?.id == attempt.id {
                restorationAttempt = nil
            }
            throw error
        }
    }

    private func performWorkspaceRestoration() async throws {
        guard ProcessInfo.processInfo.environment[
            "QUERYCRAFT_UI_TESTING"
        ] != "1" else {
            return
        }

        let states = try await restorationRepository.fetchAll()
        let profileIDs = states.reduce(into: [ConnectionProfile.ID]()) {
            profileIDs, state in
            guard !profileIDs.contains(state.connectionProfileID) else {
                return
            }
            profileIDs.append(state.connectionProfileID)
        }
        var passwords: [ConnectionProfile.ID: String] = [:]
        var canceledProfileIDs: Set<ConnectionProfile.ID> = []

        for profileID in profileIDs {
            let hasUnopenedState = states.contains {
                $0.connectionProfileID == profileID && groups[$0.id] == nil
            }
            guard hasUnopenedState else { continue }
            if let password = try await resolvePassword(
                profileID: profileID,
                attachedTo: welcomeWindow
            ) {
                passwords[profileID] = password
            } else {
                canceledProfileIDs.insert(profileID)
            }
        }

        var didRestoreWorkspace = false
        for state in states where groups[state.id] == nil {
            guard !canceledProfileIDs.contains(state.connectionProfileID),
                  let password = passwords[state.connectionProfileID]
            else {
                continue
            }
            let group = WorkspaceWindowGroup(
                restorationState: state,
                workspacePassword: password,
                restorationRepository: restorationRepository,
                workspaceManager: self,
                didClose: { [weak self] workspaceID in
                    self?.workspaceDidClose(workspaceID)
                },
                didRequestMoveDatabaseContext: { [weak self] group, contextID in
                    self?.moveDatabaseContextToNewWindow(
                        from: group,
                        contextID: contextID
                    )
                }
            )
            groups[state.id] = group
            group.open()
            didRestoreWorkspace = true
        }
        if didRestoreWorkspace {
            welcomeWindow?.orderOut(nil)
        }
    }

    private func resolvePassword(
        profileID: ConnectionProfile.ID,
        attachedTo window: NSWindow?
    ) async throws -> String? {
        if ProcessInfo.processInfo.environment["QUERYCRAFT_UI_TESTING"] == "1" {
            return ""
        }
        guard let profile = try await profileRepository.fetch(id: profileID) else {
            throw WorkspaceError.profileNotFound
        }
        if profile.authenticationMethod == .none {
            // nil means the user canceled opening/restoration. An anonymous
            // connection proceeds without a secret; authentication ignores it.
            return ""
        }
        if profile.storesCredential,
           let password = try await credentialStore.password(for: profileID)
        {
            return password
        }
        return await credentialPrompter.requestPassword(
            for: profile,
            attachedTo: window
        )
    }

    func hasOpenWorkspace(profileID: ConnectionProfile.ID) -> Bool {
        groups.values.contains {
            $0.model.profileID == profileID
        }
    }

    var openWorkspaceCount: Int {
        groups.count
    }

    @objc
    func requestCloseAllWorkspaces(_ sender: Any?) {
        _ = startCloseAllWorkspaces()
    }

    func closeAllWorkspaces() async -> Bool {
        await startCloseAllWorkspaces().value
    }

    private func startCloseAllWorkspaces() -> Task<Bool, Never> {
        if let closeAllTask {
            return closeAllTask
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let moveTasks = Array(self.databaseMoveTasks.values)
            for moveTask in moveTasks {
                await moveTask.value
            }
            let groups = Array(self.groups.values)
            for group in groups {
                guard await group.requestExplicitClose() else {
                    self.closeAllTask = nil
                    return false
                }
            }
            self.closeAllTask = nil
            return true
        }
        closeAllTask = task
        return task
    }

    private func workspaceDidClose(_ workspaceID: UUID) {
        groups.removeValue(forKey: workspaceID)
        guard groups.isEmpty else { return }
        welcomeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func moveDatabaseContextToNewWindow(
        from sourceGroup: WorkspaceWindowGroup,
        contextID: UUID
    ) {
        let workspaceID = UUID()
        guard let transfer = sourceGroup.extractDatabaseContext(
            contextID,
            updatesWindow: false
        ) else {
            return
        }
        let moveID = UUID()
        let workspaceMoveTask = transfer.0.model.startMovingToWorkspace(
            workspaceID
        )
        let group = WorkspaceWindowGroup(
            transferredContext: transfer.0,
            connectionTask: transfer.1,
            restorationRepository: restorationRepository,
            workspaceManager: self,
            didClose: { [weak self] workspaceID in
                self?.workspaceDidClose(workspaceID)
            },
            didRequestMoveDatabaseContext: { [weak self] group, contextID in
                self?.moveDatabaseContextToNewWindow(
                    from: group,
                    contextID: contextID
                )
            }
        )
        groups[workspaceID] = group
        group.open()
        sourceGroup.refreshWindowAfterDatabaseContextExtraction()

        databaseMoveTasks[moveID] = Task { @MainActor [weak self] in
            await workspaceMoveTask.value
            self?.databaseMoveTasks[moveID] = nil
        }
    }
}
