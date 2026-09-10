actor InMemoryConnectionProfileRepository: ConnectionManagementRepository {
    private var profiles: [ConnectionProfile]
    private var groups: [ConnectionGroup]

    init(
        profiles: [ConnectionProfile] = [],
        groups: [ConnectionGroup] = []
    ) {
        self.profiles = profiles
        self.groups = groups
    }

    func fetchAll() async throws -> [ConnectionProfile] {
        profiles.sorted { left, right in
            left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    func fetch(id: ConnectionProfile.ID) async throws -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    func insert(_ profile: ConnectionProfile) async throws {
        profiles.append(profile)
    }

    func update(_ profile: ConnectionProfile) async throws {
        guard let index = profiles.firstIndex(where: {
            $0.id == profile.id
        }) else {
            return
        }
        profiles[index] = profile
        normalizeProfileOrder()
    }

    func delete(id: ConnectionProfile.ID) async throws {
        profiles.removeAll { $0.id == id }
    }

    func fetchManagementSnapshot() async throws -> ConnectionManagementSnapshot {
        ConnectionManagementSnapshot(
            groups: groups.sorted(by: Self.groupDisplayOrder),
            profiles: profiles.sorted(by: Self.profileDisplayOrder)
        )
    }

    func insert(_ group: ConnectionGroup) async throws {
        groups.append(group)
    }

    func update(_ group: ConnectionGroup) async throws {
        guard let index = groups.firstIndex(where: {
            $0.id == group.id
        }) else {
            return
        }
        groups[index] = group
    }

    func deletionImpact(
        profileIDs: [ConnectionProfile.ID]
    ) async throws -> ConnectionDeletionImpact {
        let affectedProfiles = profiles.filter {
            profileIDs.contains($0.id)
        }
        return ConnectionDeletionImpact(
            connectionProfileCount: affectedProfiles.count,
            savedQueryCount: 0,
            recoverableDraftCount: 0,
            workspaceRestorationCount: 0,
            storedCredentialCount: affectedProfiles.count(where: \.storesCredential)
        )
    }

    func deleteProfiles(ids: [ConnectionProfile.ID]) async throws {
        profiles.removeAll { ids.contains($0.id) }
        normalizeProfileOrder()
    }

    func deleteGroup(id: ConnectionGroup.ID) async throws {
        groups.removeAll { $0.id == id }
        profiles.removeAll { $0.groupID == id }
        normalizeGroupOrder()
    }

    func moveProfile(
        id: ConnectionProfile.ID,
        toGroupID: ConnectionGroup.ID?,
        beforeProfileID: ConnectionProfile.ID?
    ) async throws {
        guard let movingProfile = profiles.first(where: {
            $0.id == id
        }) else {
            return
        }
        profiles.removeAll { $0.id == id }
        var destination = profiles
            .filter { $0.groupID == toGroupID }
            .sorted(by: Self.profileDisplayOrder)
        let insertionIndex = beforeProfileID.flatMap { beforeID in
            destination.firstIndex(where: { $0.id == beforeID })
        } ?? destination.endIndex
        destination.insert(
            movingProfile.placing(
                in: toGroupID,
                sortIndex: insertionIndex
            ),
            at: insertionIndex
        )
        let destinationIDs = Set(destination.map(\.id))
        profiles.removeAll { destinationIDs.contains($0.id) }
        profiles.append(
            contentsOf: destination.enumerated().map { index, profile in
                profile.placing(in: toGroupID, sortIndex: index)
            }
        )
        normalizeProfileOrder()
    }

    func moveGroup(
        id: ConnectionGroup.ID,
        beforeGroupID: ConnectionGroup.ID?
    ) async throws {
        guard let movingGroup = groups.first(where: {
            $0.id == id
        }) else {
            return
        }
        groups.removeAll { $0.id == id }
        groups.sort(by: Self.groupDisplayOrder)
        let insertionIndex = beforeGroupID.flatMap { beforeID in
            groups.firstIndex(where: { $0.id == beforeID })
        } ?? groups.endIndex
        groups.insert(movingGroup, at: insertionIndex)
        reindexGroupsInCurrentOrder()
    }

    private func normalizeProfileOrder() {
        let groupIDs = Set(profiles.map(\.groupID))
        for groupID in groupIDs {
            let ordered = profiles
                .filter { $0.groupID == groupID }
                .sorted(by: Self.profileDisplayOrder)
            let orderedIDs = Set(ordered.map(\.id))
            profiles.removeAll { orderedIDs.contains($0.id) }
            profiles.append(
                contentsOf: ordered.enumerated().map { index, profile in
                    profile.placing(in: groupID, sortIndex: index)
                }
            )
        }
    }

    private func normalizeGroupOrder() {
        groups = groups
            .sorted(by: Self.groupDisplayOrder)
        reindexGroupsInCurrentOrder()
    }

    private func reindexGroupsInCurrentOrder() {
        groups = groups
            .enumerated()
            .map { index, group in
                ConnectionGroup(
                    id: group.id,
                    name: group.name,
                    sortIndex: index,
                    createdAt: group.createdAt
                )
            }
    }

    private static func groupDisplayOrder(
        _ left: ConnectionGroup,
        _ right: ConnectionGroup
    ) -> Bool {
        if left.sortIndex != right.sortIndex {
            return left.sortIndex < right.sortIndex
        }
        return left.name.localizedStandardCompare(right.name)
            == .orderedAscending
    }

    private static func profileDisplayOrder(
        _ left: ConnectionProfile,
        _ right: ConnectionProfile
    ) -> Bool {
        if left.groupID != right.groupID {
            return String(describing: left.groupID)
                < String(describing: right.groupID)
        }
        if left.sortIndex != right.sortIndex {
            return left.sortIndex < right.sortIndex
        }
        return left.name.localizedStandardCompare(right.name)
            == .orderedAscending
    }
}

private extension ConnectionProfile {
    func placing(
        in groupID: ConnectionGroup.ID?,
        sortIndex: Int
    ) -> ConnectionProfile {
        ConnectionProfile(
            id: id,
            name: name,
            groupID: groupID,
            databaseType: databaseType,
            databaseProduct: databaseProduct,
            host: host,
            port: port,
            username: username,
            defaultDatabase: defaultDatabase,
            tlsMode: tlsMode,
            storesCredential: storesCredential,
            sortIndex: sortIndex,
            createdAt: createdAt
        )
    }
}
