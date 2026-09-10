import SwiftUI

struct ConnectionProfilesPane: View {
    let model: WelcomeModel
    let openProfile: (ConnectionProfile) -> Void
    let createProfile: (ConnectionGroup.ID?) -> Void
    let editProfile: (ConnectionProfile) -> Void
    let deleteProfile: (ConnectionProfile) -> Void
    let createGroup: () -> Void
    let renameGroup: (ConnectionGroup) -> Void
    let deleteGroup: (ConnectionGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConnectionProfilesHeader(
                profileCount: model.profiles.count,
                createProfile: { createProfile(nil) },
                createGroup: createGroup
            )

            Divider()

            ZStack {
                Color.welcomeSecondaryPane
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                if model.profiles.isEmpty && model.groups.isEmpty {
                    ContentUnavailableView(
                        AppCopy.current.text("暂无连接", "No Connections"),
                        systemImage: "cylinder",
                        description: Text(
                            AppCopy.current.text(
                                "创建连接以开始使用数据库工作区。",
                                "Create a connection to start a database workspace."
                            )
                        )
                    )
                    .accessibilityIdentifier("emptyConnectionProfilesMessage")
                } else {
                    ConnectionProfilesOutlineView(
                        groups: model.groups,
                        profiles: model.profiles,
                        openProfile: openProfile,
                        createProfile: createProfile,
                        editProfile: editProfile,
                        duplicateProfile: duplicate,
                        deleteProfile: deleteProfile,
                        renameGroup: renameGroup,
                        deleteGroup: deleteGroup,
                        moveProfile: moveProfile,
                        moveGroup: moveGroup
                    )
                    .accessibilityIdentifier("connectionProfilesList")
                }
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.welcomeSecondaryPane)
    }

    private func duplicate(_ profile: ConnectionProfile) {
        Task {
            do {
                try await model.duplicateProfile(profile)
            } catch {
                model.present(error)
            }
        }
    }

    private func moveProfile(
        id: ConnectionProfile.ID,
        toGroupID: ConnectionGroup.ID?,
        beforeProfileID: ConnectionProfile.ID?
    ) {
        Task {
            do {
                try await model.moveProfile(
                    id: id,
                    toGroupID: toGroupID,
                    beforeProfileID: beforeProfileID
                )
            } catch {
                model.present(error)
            }
        }
    }

    private func moveGroup(
        id: ConnectionGroup.ID,
        beforeGroupID: ConnectionGroup.ID?
    ) {
        Task {
            do {
                try await model.moveGroup(
                    id: id,
                    beforeGroupID: beforeGroupID
                )
            } catch {
                model.present(error)
            }
        }
    }
}
