import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite(.serialized)
struct WorkspaceWindowManagerTests {
    @Test
    func anonymousProfileOpensWithoutCredentialsAndReusesWorkspace() async throws {
        let profile = makeAnonymousProfile()
        let credentials = ObservedWorkspaceCredentialStore()
        let prompter = FixedWorkspaceCredentialPrompter(password: nil)
        let manager = WorkspaceWindowManager(
            restorationRepository: InMemoryWorkspaceRestorationRepository(),
            profileRepository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: credentials,
            credentialPrompter: prompter
        )

        #expect(try await manager.openWorkspace(profileID: profile.id, welcomeWindow: nil))
        #expect(try await manager.openWorkspace(profileID: profile.id, welcomeWindow: nil))
        #expect(manager.openWorkspaceCount == 1)
        #expect(prompter.requestCount == 0)
        #expect(await credentials.readCount == 0)
        #expect(await manager.closeAllWorkspaces())
    }

    @Test
    func anonymousRestorationOpensEveryWorkspaceWithoutCredentials() async throws {
        let profile = makeAnonymousProfile()
        let states = [makeRestorationState(profileID: profile.id),
                      makeRestorationState(profileID: profile.id)]
        let credentials = ObservedWorkspaceCredentialStore()
        let prompter = FixedWorkspaceCredentialPrompter(password: nil)
        let manager = WorkspaceWindowManager(
            restorationRepository: InMemoryWorkspaceRestorationRepository(states: states),
            profileRepository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: credentials,
            credentialPrompter: prompter
        )

        try await manager.restoreWorkspaces(welcomeWindow: nil)
        #expect(manager.openWorkspaceCount == 2)
        try await manager.restoreWorkspaces(welcomeWindow: nil)
        #expect(manager.openWorkspaceCount == 2)
        #expect(prompter.requestCount == 0)
        #expect(await credentials.readCount == 0)
        #expect(await manager.closeAllWorkspaces())
    }

    @Test
    func concurrentRestorationCallersWaitForOneSharedAttempt() async throws {
        let repository = SuspendedWorkspaceRestorationRepository()
        let manager = WorkspaceWindowManager(
            restorationRepository: repository
        )
        let secondCall = CompletionFlag()

        let firstTask = Task { @MainActor in
            try await manager.restoreWorkspaces(welcomeWindow: nil)
        }
        await repository.waitUntilFetchStarts()

        let secondTask = Task { @MainActor in
            try await manager.restoreWorkspaces(welcomeWindow: nil)
            await secondCall.markCompleted()
        }
        await Task.yield()

        #expect(await repository.fetchCount == 1)
        #expect(await !secondCall.isCompleted)

        await repository.finishFetch()
        try await firstTask.value
        try await secondTask.value

        try await manager.restoreWorkspaces(welcomeWindow: nil)
        #expect(await repository.fetchCount == 1)
    }

    @Test
    func repeatedProfileOpenReusesItsExistingWorkspace() async {
        let repository = InMemoryWorkspaceRestorationRepository()
        let profile = makeProfile()
        let manager = WorkspaceWindowManager(
            restorationRepository: repository,
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialPrompter: FixedWorkspaceCredentialPrompter(
                password: "secret"
            )
        )
        _ = try? await manager.openWorkspace(
            profileID: profile.id,
            welcomeWindow: nil
        )
        _ = try? await manager.openWorkspace(
            profileID: profile.id,
            welcomeWindow: nil
        )

        #expect(manager.openWorkspaceCount == 1)

        #expect(await manager.closeAllWorkspaces())
    }

    @Test
    func workspaceConnectionOpenKeepsPresentingWindowVisibleAndReusesTarget()
        async throws
    {
        let repository = InMemoryWorkspaceRestorationRepository()
        let firstProfile = makeProfile()
        let secondProfile = makeProfile()
        let prompter = FixedWorkspaceCredentialPrompter(password: "secret")
        let manager = WorkspaceWindowManager(
            restorationRepository: repository,
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [firstProfile, secondProfile]
            ),
            credentialPrompter: prompter
        )
        let presentingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        presentingWindow.isReleasedWhenClosed = false
        presentingWindow.orderFront(nil)
        defer { presentingWindow.close() }

        #expect(
            try await manager.openWorkspace(
                profileID: firstProfile.id,
                attachedTo: presentingWindow
            )
        )
        #expect(presentingWindow.isVisible)
        #expect(prompter.attachedWindow === presentingWindow)

        #expect(
            try await manager.openWorkspace(
                profileID: secondProfile.id,
                attachedTo: presentingWindow
            )
        )
        #expect(manager.openWorkspaceCount == 2)

        #expect(
            try await manager.openWorkspace(
                profileID: secondProfile.id,
                attachedTo: presentingWindow
            )
        )
        #expect(manager.openWorkspaceCount == 2)
        #expect(presentingWindow.isVisible)
        #expect(await manager.closeAllWorkspaces())
    }

    @Test
    func connectionPickerProfilesComeFromCurrentRepository() async throws {
        let firstProfile = makeProfile()
        let secondProfile = makeProfile()
        let manager = WorkspaceWindowManager(
            restorationRepository: InMemoryWorkspaceRestorationRepository(),
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [firstProfile, secondProfile]
            )
        )

        let profiles = try await manager.fetchConnectionProfiles()

        #expect(Set(profiles.map(\.id)) == [firstProfile.id, secondProfile.id])
    }

    @Test
    func closeAllExplicitlyClosesEveryWorkspaceAndDeletesRestoration()
        async throws
    {
        let repository = InMemoryWorkspaceRestorationRepository()
        let firstProfile = makeProfile()
        let secondProfile = makeProfile()
        let manager = WorkspaceWindowManager(
            restorationRepository: repository,
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [firstProfile, secondProfile]
            ),
            credentialPrompter: FixedWorkspaceCredentialPrompter(
                password: "secret"
            )
        )
        try await manager.openWorkspace(
            profileID: firstProfile.id,
            welcomeWindow: nil
        )
        try await manager.openWorkspace(
            profileID: secondProfile.id,
            welcomeWindow: nil
        )

        #expect(manager.openWorkspaceCount == 2)

        #expect(await manager.closeAllWorkspaces())
        #expect(manager.openWorkspaceCount == 0)
        #expect(try await repository.fetchAll().isEmpty)
    }

    @Test
    func workspaceIsNotCreatedUntilPasswordPromptCompletes() async throws {
        let profile = makeProfile()
        let prompter = SuspendedWorkspaceCredentialPrompter()
        let manager = WorkspaceWindowManager(
            restorationRepository: InMemoryWorkspaceRestorationRepository(),
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialPrompter: prompter
        )
        let openTask = Task { @MainActor in
            try await manager.openWorkspace(
                profileID: profile.id,
                welcomeWindow: nil
            )
        }
        await prompter.waitUntilRequested()

        #expect(manager.openWorkspaceCount == 0)

        prompter.finish(with: "entered-password")
        #expect(try await openTask.value)
        #expect(manager.openWorkspaceCount == 1)

        #expect(await manager.closeAllWorkspaces())
    }

    @Test
    func cancelingPasswordPromptLeavesWorkspaceClosed() async throws {
        let profile = makeProfile()
        let manager = WorkspaceWindowManager(
            restorationRepository: InMemoryWorkspaceRestorationRepository(),
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialPrompter: FixedWorkspaceCredentialPrompter(password: nil)
        )
        let didOpen = try await manager.openWorkspace(
            profileID: profile.id,
            welcomeWindow: nil
        )

        #expect(!didOpen)
        #expect(manager.openWorkspaceCount == 0)
    }

    @Test
    func storedCredentialOpensWithoutPrompting() async throws {
        let profile = makeProfile(storesCredential: true)
        let prompter = FixedWorkspaceCredentialPrompter(password: nil)
        let manager = WorkspaceWindowManager(
            restorationRepository: InMemoryWorkspaceRestorationRepository(),
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(
                passwords: [profile.id: "stored-password"]
            ),
            credentialPrompter: prompter
        )
        let didOpen = try await manager.openWorkspace(
            profileID: profile.id,
            welcomeWindow: nil
        )

        #expect(didOpen)
        #expect(prompter.requestCount == 0)
        #expect(manager.openWorkspaceCount == 1)
        #expect(await manager.closeAllWorkspaces())
    }

    @Test
    func cancelingRestorationKeepsItsPersistedState() async throws {
        let profile = makeProfile()
        let state = makeRestorationState(profileID: profile.id)
        let repository = InMemoryWorkspaceRestorationRepository(states: [state])
        let manager = WorkspaceWindowManager(
            restorationRepository: repository,
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialPrompter: FixedWorkspaceCredentialPrompter(password: nil)
        )
        try await manager.restoreWorkspaces(welcomeWindow: nil)

        #expect(manager.openWorkspaceCount == 0)
        #expect(try await repository.fetchAll() == [state])
    }

    @Test
    func restorationPromptsOnceForMultipleWorkspacesOfOneProfile()
        async throws
    {
        let profile = makeProfile()
        let states = [makeRestorationState(profileID: profile.id),
                      makeRestorationState(profileID: profile.id)]
        let prompter = FixedWorkspaceCredentialPrompter(password: "secret")
        let manager = WorkspaceWindowManager(
            restorationRepository: InMemoryWorkspaceRestorationRepository(
                states: states
            ),
            profileRepository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialPrompter: prompter
        )
        try await manager.restoreWorkspaces(welcomeWindow: nil)

        #expect(prompter.requestCount == 1)
        #expect(manager.openWorkspaceCount == 2)

        #expect(await manager.closeAllWorkspaces())
    }

    private func makeAnonymousProfile() -> ConnectionProfile {
        ConnectionProfile(id: UUID(), name: "Anonymous Elasticsearch", groupID: nil,
            databaseType: .elasticsearch, host: "127.0.0.1", port: 19280,
            username: "", authenticationMethod: .none, defaultDatabase: nil,
            tlsMode: .disabled, storesCredential: true, createdAt: .now)
    }

    private func makeProfile(
        id: UUID = UUID(),
        storesCredential: Bool = false
    ) -> ConnectionProfile {
        ConnectionProfile(
            id: id,
            name: "Local MySQL",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "root",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: storesCredential,
            createdAt: .now
        )
    }

    private func makeRestorationState(
        profileID: ConnectionProfile.ID
    ) -> WorkspaceRestorationState {
        let contextID = UUID()
        return WorkspaceRestorationState(
            id: UUID(),
            connectionProfileID: profileID,
            databaseContexts: [
                WorkspaceDatabaseContextRestorationState(
                    id: contextID,
                    databaseName: nil,
                    selectedObject: nil,
                    queryDocuments: [],
                    selectedQueryDocumentID: nil,
                    contentTabOrder: [],
                    selectedContentTab: nil,
                    sidebarMode: .items
                )
            ],
            selectedDatabaseContextID: contextID,
            windowFrame: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

}

private actor ObservedWorkspaceCredentialStore: CredentialStore {
    private(set) var readCount = 0
    func password(for profileID: UUID) async throws -> String? {
        readCount += 1
        return "stale-secret"
    }
    func save(password: String, for profileID: UUID) async throws {}
    func delete(for profileID: UUID) async throws {}
}

@MainActor
private final class FixedWorkspaceCredentialPrompter:
    WorkspaceCredentialPrompting
{
    let password: String?
    private(set) var requestCount = 0
    private(set) weak var attachedWindow: NSWindow?

    init(password: String?) {
        self.password = password
    }

    func requestPassword(
        for profile: ConnectionProfile,
        attachedTo window: NSWindow?
    ) async -> String? {
        requestCount += 1
        attachedWindow = window
        return password
    }
}

@MainActor
private final class SuspendedWorkspaceCredentialPrompter:
    WorkspaceCredentialPrompting
{
    private var wasRequested = false
    private var continuation: CheckedContinuation<String?, Never>?

    func requestPassword(
        for profile: ConnectionProfile,
        attachedTo window: NSWindow?
    ) async -> String? {
        wasRequested = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while !wasRequested {
            await Task.yield()
        }
    }

    func finish(with password: String?) {
        continuation?.resume(returning: password)
        continuation = nil
    }
}

private actor CompletionFlag {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private actor SuspendedWorkspaceRestorationRepository:
    WorkspaceRestorationRepository
{
    private(set) var fetchCount = 0
    private var fetchContinuation:
        CheckedContinuation<[WorkspaceRestorationState], Never>?

    func fetchAll() async throws -> [WorkspaceRestorationState] {
        fetchCount += 1
        return await withCheckedContinuation { continuation in
            fetchContinuation = continuation
        }
    }

    func fetch(id: WorkspaceRestorationState.ID) async throws
        -> WorkspaceRestorationState?
    {
        nil
    }

    func save(_ state: WorkspaceRestorationState) async throws {}

    func delete(id: WorkspaceRestorationState.ID) async throws {}

    func waitUntilFetchStarts() async {
        while fetchCount == 0 {
            await Task.yield()
        }
    }

    func finishFetch() {
        fetchContinuation?.resume(returning: [])
        fetchContinuation = nil
    }
}
