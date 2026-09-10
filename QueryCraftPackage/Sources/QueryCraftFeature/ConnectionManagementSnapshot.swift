struct ConnectionManagementSnapshot: Equatable, Sendable {
    let groups: [ConnectionGroup]
    let profiles: [ConnectionProfile]
}
