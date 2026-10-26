import Foundation

struct ConnectionProfilesSearchResults {
    let groups: [ConnectionGroup]
    let profiles: [ConnectionProfile]
    let sshProfiles: [SSHConnection]
    let query: String
    let showsUngrouped: Bool

    var isSearching: Bool { !query.isEmpty }

    init(groups: [ConnectionGroup], profiles: [ConnectionProfile], searchText: String, sshProfiles: [SSHConnection] = []) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        guard !query.isEmpty else {
            self.groups = groups
            self.profiles = profiles
            self.sshProfiles = sshProfiles
            showsUngrouped = true
            return
        }

        let matchingGroupIDs = Set(groups.filter {
            $0.name.localizedStandardContains(query)
        }.map(\.id))
        let matchesUngrouped = AppCopy.current.text("未分组", "Ungrouped")
            .localizedStandardContains(query)
        let matchingProfiles = profiles.filter { profile in
            let matchesGroup = profile.groupID.map(matchingGroupIDs.contains)
                ?? matchesUngrouped
            return matchesGroup
                || profile.name.localizedStandardContains(query)
                || "\(profile.username)@\(profile.host):\(profile.port)"
                    .localizedStandardContains(query)
        }
        let matchingSSH = sshProfiles.filter { profile in
            let matchesGroup = profile.groupID.map(matchingGroupIDs.contains) ?? matchesUngrouped
            return matchesGroup || !SSHWelcomeSearch.filter([profile], query: query).isEmpty
        }
        self.sshProfiles = matchingSSH
        let visibleGroupIDs = Set(matchingProfiles.compactMap(\.groupID) + matchingSSH.compactMap(\.groupID))
        self.groups = groups.filter {
            matchingGroupIDs.contains($0.id) || visibleGroupIDs.contains($0.id)
        }
        self.profiles = matchingProfiles
        showsUngrouped = matchesUngrouped || matchingProfiles.contains { $0.groupID == nil } || matchingSSH.contains { $0.groupID.map { id in !groups.contains { $0.id == id } } ?? true }
    }
}
