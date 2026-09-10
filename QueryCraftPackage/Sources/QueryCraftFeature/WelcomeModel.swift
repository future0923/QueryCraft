import Foundation
import Observation

@MainActor
@Observable
final class WelcomeModel {
    private(set) var profiles: [ConnectionProfile] = []
    private(set) var groups: [ConnectionGroup] = []
    var loadErrorMessage = ""
    var isShowingLoadError = false

    private let repository: any ConnectionManagementRepository
    private let credentialStore: any CredentialStore
    private let connectionTester: any ConnectionTester
    private let profileOwnsOpenWorkspace:
        @MainActor (ConnectionProfile.ID) -> Bool

    init(
        repository: any ConnectionManagementRepository,
        credentialStore: any CredentialStore,
        connectionTester: any ConnectionTester,
        profiles: [ConnectionProfile] = [],
        groups: [ConnectionGroup] = [],
        profileOwnsOpenWorkspace:
            @escaping @MainActor (ConnectionProfile.ID) -> Bool = { _ in false }
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.connectionTester = connectionTester
        self.profiles = profiles
        self.groups = groups
        self.profileOwnsOpenWorkspace = profileOwnsOpenWorkspace
    }

    func loadProfiles() async {
        do {
            try await refresh()
        } catch {
            present(error)
        }
    }

    func createProfile(from draft: ConnectionProfileDraft) async throws {
        try validate(groupID: draft.groupID)
        let profile = try draft.makeProfile(
            sortIndex: nextProfileSortIndex(in: draft.groupID)
        )

        if profile.storesCredential {
            try await credentialStore.save(password: draft.password, for: profile.id)
        }

        do {
            try await repository.insert(profile)
        } catch {
            if profile.storesCredential {
                try? await credentialStore.delete(for: profile.id)
            }
            throw error
        }

        try await refresh()
    }

    func draft(for profile: ConnectionProfile) async throws
        -> ConnectionProfileDraft
    {
        let password: String
        if profile.storesCredential {
            password = try await credentialStore.password(
                for: profile.id
            ) ?? ""
        } else {
            password = ""
        }
        return ConnectionProfileDraft(
            profile: profile,
            password: password
        )
    }

    func updateProfile(
        _ profile: ConnectionProfile,
        from draft: ConnectionProfileDraft
    ) async throws {
        try validate(groupID: draft.groupID)
        let sortIndex = draft.groupID == profile.groupID
            ? profile.sortIndex
            : nextProfileSortIndex(in: draft.groupID)
        let updatedProfile = try draft.makeProfile(
            id: profile.id,
            sortIndex: sortIndex,
            createdAt: profile.createdAt
        )
        let previousPassword = try await credentialStore.password(
            for: profile.id
        )

        try await applyCredential(
            password: draft.password,
            storesCredential: updatedProfile.storesCredential,
            profileID: profile.id
        )
        do {
            try await repository.update(updatedProfile)
        } catch {
            try? await restoreCredential(
                password: previousPassword,
                profileID: profile.id
            )
            throw error
        }
        try await refresh()
    }

    @discardableResult
    func duplicateProfile(
        _ profile: ConnectionProfile
    ) async throws -> ConnectionProfile {
        guard profiles.contains(where: { $0.id == profile.id }) else {
            throw WelcomeManagementError.missingProfile
        }
        let duplicate = ConnectionProfile(
            id: UUID(),
            name: nextDuplicateName(for: profile),
            groupID: profile.groupID,
            databaseType: profile.databaseType,
            databaseProduct: profile.databaseProduct,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            authenticationMethod: profile.authenticationMethod,
            defaultDatabase: profile.defaultDatabase,
            tlsMode: profile.tlsMode,
            storesCredential: false,
            sortIndex: nextProfileSortIndex(in: profile.groupID),
            createdAt: .now
        )
        try await repository.insert(duplicate)
        try await refresh()
        return duplicate
    }

    func createGroup(named proposedName: String) async throws {
        let name = try validatedGroupName(
            proposedName,
            excluding: nil
        )
        let group = ConnectionGroup(
            id: UUID(),
            name: name,
            sortIndex: groups.count,
            createdAt: .now
        )
        try await repository.insert(group)
        try await refresh()
    }

    func renameGroup(
        _ group: ConnectionGroup,
        to proposedName: String
    ) async throws {
        guard groups.contains(where: { $0.id == group.id }) else {
            throw WelcomeManagementError.missingGroup
        }
        let name = try validatedGroupName(
            proposedName,
            excluding: group.id
        )
        try await repository.update(
            ConnectionGroup(
                id: group.id,
                name: name,
                sortIndex: group.sortIndex,
                createdAt: group.createdAt
            )
        )
        try await refresh()
    }

    func deletionRequest(
        for profile: ConnectionProfile
    ) async throws -> ConnectionDeletionRequest {
        guard profiles.contains(where: { $0.id == profile.id }) else {
            throw WelcomeManagementError.missingProfile
        }
        try ensureProfilesCanBeDeleted(
            [profile],
            groupName: nil
        )
        let impact = try await repository.deletionImpact(
            profileIDs: [profile.id]
        )
        return ConnectionDeletionRequest(
            target: .profile(id: profile.id, name: profile.name),
            profileIDs: [profile.id],
            impact: impact
        )
    }

    func deletionRequest(
        for group: ConnectionGroup
    ) async throws -> ConnectionDeletionRequest {
        guard groups.contains(where: { $0.id == group.id }) else {
            throw WelcomeManagementError.missingGroup
        }
        let affectedProfiles = profiles.filter {
            $0.groupID == group.id
        }
        try ensureProfilesCanBeDeleted(
            affectedProfiles,
            groupName: group.name
        )
        let profileIDs = affectedProfiles.map(\.id)
        let impact = try await repository.deletionImpact(
            profileIDs: profileIDs
        )
        return ConnectionDeletionRequest(
            target: .group(id: group.id, name: group.name),
            profileIDs: profileIDs,
            impact: impact
        )
    }

    func delete(_ request: ConnectionDeletionRequest) async throws {
        let affectedProfiles: [ConnectionProfile]
        switch request.target {
        case .profile(let id, _):
            affectedProfiles = profiles.filter { $0.id == id }
        case .group(let id, _):
            affectedProfiles = profiles.filter { $0.groupID == id }
        }
        guard Set(affectedProfiles.map(\.id))
                == Set(request.profileIDs) else {
            throw WelcomeManagementError.deletionContentsChanged
        }
        try ensureProfilesCanBeDeleted(
            affectedProfiles,
            groupName: request.isGroup ? request.name : nil
        )
        let currentImpact = try await repository.deletionImpact(
            profileIDs: request.profileIDs
        )
        guard currentImpact == request.impact else {
            throw WelcomeManagementError.deletionContentsChanged
        }

        let savedPasswords = try await storedPasswords(
            for: affectedProfiles
        )
        do {
            for profile in affectedProfiles where profile.storesCredential {
                try await credentialStore.delete(for: profile.id)
            }
        } catch {
            await restoreCredentials(savedPasswords)
            throw error
        }

        do {
            switch request.target {
            case .profile:
                try await repository.deleteProfiles(
                    ids: request.profileIDs
                )
            case .group(let id, _):
                try await repository.deleteGroup(id: id)
            }
        } catch {
            await restoreCredentials(savedPasswords)
            throw error
        }
        try await refresh()
    }

    func moveProfile(
        id: ConnectionProfile.ID,
        toGroupID: ConnectionGroup.ID?,
        beforeProfileID: ConnectionProfile.ID?
    ) async throws {
        try validate(groupID: toGroupID)
        try await repository.moveProfile(
            id: id,
            toGroupID: toGroupID,
            beforeProfileID: beforeProfileID
        )
        try await refresh()
    }

    func moveGroup(
        id: ConnectionGroup.ID,
        beforeGroupID: ConnectionGroup.ID?
    ) async throws {
        try await repository.moveGroup(
            id: id,
            beforeGroupID: beforeGroupID
        )
        try await refresh()
    }

    func profiles(in groupID: ConnectionGroup.ID?) -> [ConnectionProfile] {
        profiles
            .filter { $0.groupID == groupID }
            .sorted(by: Self.profileDisplayOrder)
    }

    func present(_ error: Error) {
        loadErrorMessage = error.localizedDescription
        isShowingLoadError = true
    }

    func testConnection(from draft: ConnectionProfileDraft) async throws {
        let configuration = try draft.makeConnectionConfiguration()
        try await connectionTester.test(configuration)
    }

    static func makeDefault() -> WelcomeModel {
        if ProcessInfo.processInfo.environment["QUERYCRAFT_UI_TESTING"] == "1" {
            return WelcomeModel(
                repository: InMemoryConnectionProfileRepository(
                    profiles: QueryCraftUITestFixtures.profiles
                ),
                credentialStore: InMemoryCredentialStore(),
                connectionTester: InMemoryConnectionTester(),
                profiles: QueryCraftUITestFixtures.profiles
            )
        }

        return WelcomeModel(
            repository: SQLiteConnectionProfileRepository(),
            credentialStore: KeychainCredentialStore(),
            connectionTester: DatabaseDriverConnectionTester(),
            profileOwnsOpenWorkspace: {
                WorkspaceWindowManager.shared.hasOpenWorkspace(
                    profileID: $0
                )
            }
        )
    }

    private func refresh() async throws {
        let snapshot = try await repository.fetchManagementSnapshot()
        groups = snapshot.groups
        profiles = snapshot.profiles
    }

    private func validate(groupID: ConnectionGroup.ID?) throws {
        guard let groupID else { return }
        guard groups.contains(where: { $0.id == groupID }) else {
            throw WelcomeManagementError.missingGroup
        }
    }

    private func validatedGroupName(
        _ proposedName: String,
        excluding groupID: ConnectionGroup.ID?
    ) throws -> String {
        let name = proposedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            throw WelcomeManagementError.emptyGroupName
        }
        guard !groups.contains(where: {
            $0.id != groupID
                && $0.name.compare(
                    name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        }) else {
            throw WelcomeManagementError.duplicateGroupName(name)
        }
        return name
    }

    private func nextProfileSortIndex(
        in groupID: ConnectionGroup.ID?
    ) -> Int {
        (profiles(in: groupID).map(\.sortIndex).max() ?? -1) + 1
    }

    private func nextDuplicateName(
        for profile: ConnectionProfile
    ) -> String {
        let existingNames = Set(
            profiles(in: profile.groupID).map {
                $0.name.lowercased()
            }
        )
        var copyNumber = 1
        while true {
            let suffix = copyNumber == 1
                ? AppCopy.current.text("副本", "Copy")
                : AppCopy.current.text(
                    "副本 \(copyNumber)",
                    "Copy \(copyNumber)"
                )
            let candidate = "\(profile.name) \(suffix)"
            if !existingNames.contains(candidate.lowercased()) {
                return candidate
            }
            copyNumber += 1
        }
    }

    private func ensureProfilesCanBeDeleted(
        _ affectedProfiles: [ConnectionProfile],
        groupName: String?
    ) throws {
        guard let openProfile = affectedProfiles.first(where: {
            profileOwnsOpenWorkspace($0.id)
        }) else {
            return
        }
        if let groupName {
            throw WelcomeManagementError.groupOwnsOpenWorkspace(
                groupName: groupName,
                profileName: openProfile.name
            )
        }
        throw WelcomeManagementError.profileOwnsOpenWorkspace(
            openProfile.name
        )
    }

    private func storedPasswords(
        for affectedProfiles: [ConnectionProfile]
    ) async throws -> [ConnectionProfile.ID: String] {
        var passwords: [ConnectionProfile.ID: String] = [:]
        for profile in affectedProfiles where profile.storesCredential {
            if let password = try await credentialStore.password(
                for: profile.id
            ) {
                passwords[profile.id] = password
            }
        }
        return passwords
    }

    private func restoreCredentials(
        _ passwords: [ConnectionProfile.ID: String]
    ) async {
        for (profileID, password) in passwords {
            try? await credentialStore.save(
                password: password,
                for: profileID
            )
        }
    }

    private func applyCredential(
        password: String,
        storesCredential: Bool,
        profileID: ConnectionProfile.ID
    ) async throws {
        if storesCredential {
            try await credentialStore.save(
                password: password,
                for: profileID
            )
        } else {
            try await credentialStore.delete(for: profileID)
        }
    }

    private func restoreCredential(
        password: String?,
        profileID: ConnectionProfile.ID
    ) async throws {
        if let password {
            try await credentialStore.save(
                password: password,
                for: profileID
            )
        } else {
            try await credentialStore.delete(for: profileID)
        }
    }

    private static func profileDisplayOrder(
        _ left: ConnectionProfile,
        _ right: ConnectionProfile
    ) -> Bool {
        if left.sortIndex != right.sortIndex {
            return left.sortIndex < right.sortIndex
        }
        return left.name.localizedStandardCompare(right.name)
            == .orderedAscending
    }
}
