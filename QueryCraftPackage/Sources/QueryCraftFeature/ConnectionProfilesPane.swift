import SwiftUI

struct ConnectionProfilesPane: View {
    let model: WelcomeModel
    var openSSH: ((SSHConnection) -> Void)? = nil
    var createSSH: (() -> Void)? = nil
    var editSSH: ((SSHConnection) -> Void)? = nil
    var deleteSSH: ((SSHConnection) -> Void)? = nil
    let openProfile: (ConnectionProfile) -> Void
    let createProfile: (ConnectionGroup.ID?) -> Void
    let editProfile: (ConnectionProfile) -> Void
    let deleteProfile: (ConnectionProfile) -> Void
    let createGroup: () -> Void
    let renameGroup: (ConnectionGroup) -> Void
    let deleteGroup: (ConnectionGroup) -> Void
    @State private var searchText = ""

    var body: some View {
        let results = ConnectionProfilesSearchResults(
            groups: model.groups,
            profiles: model.profiles,
            searchText: searchText, sshProfiles: model.ssh?.profiles ?? []
        )
        let sshProfiles = results.sshProfiles
        VStack(spacing: 0) {
            ConnectionProfilesHeader(
                profileCount: model.connectionCount,
                searchText: $searchText,
                createProfile: { createProfile(nil) },
                createGroup: createGroup
            )

            Divider()

            ZStack {
                Color.welcomeSecondaryPane
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                if model.hasLoadedProfiles && model.ssh?.loaded != false && model.ssh?.error == nil && model.profiles.isEmpty && model.groups.isEmpty && (model.ssh?.profiles.isEmpty ?? true) {
                    ContentUnavailableView(
                        AppCopy.current.text("暂无连接", "No Connections"),
                        systemImage: "cylinder",
                        description: Text(
                            AppCopy.current.text(
                                "创建数据库或 SSH 连接以开始使用。",
                                "Create a database or SSH connection to get started."
                            )
                        )
                    )
                    .accessibilityIdentifier("emptyConnectionProfilesMessage")
                } else {
                    ConnectionProfilesOutlineView(
                        groups: results.groups,
                        profiles: results.profiles,
                        sshProfiles: sshProfiles, openSSH: openSSH, createSSH: createSSH, editSSH: editSSH, deleteSSH: deleteSSH,
                        moveSSH: { profile, groupID, beforeID in
                            Task {
                                do { try await model.ssh?.service.move(profile, to: groupID, beforeID: beforeID); await model.ssh?.load() }
                                catch { model.present(error) }
                            }
                        },
                        searchQuery: results.query,
                        showsUngrouped: results.showsUngrouped,
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
                    .overlay {
                        if model.hasLoadedProfiles && model.ssh?.loaded != false && model.ssh?.error == nil
                            && results.isSearching && results.groups.isEmpty
                            && results.profiles.isEmpty && sshProfiles.isEmpty && !results.showsUngrouped
                        {
                            ContentUnavailableView.search(text: results.query)
                                .accessibilityIdentifier("emptyConnectionSearchMessage")
                        }
                    }
                }
            }
            if let ssh = model.ssh {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini).frame(width: 14).opacity(ssh.busy ? 1 : 0)
                    Text(ssh.error ?? "").font(.caption).foregroundStyle(.red).lineLimit(1).help(ssh.error ?? "")
                    Spacer(minLength: 4)
                    if ssh.error != nil { Button(AppCopy.current.text("重试", "Retry")) { Task { await ssh.load() } }.buttonStyle(.borderless) }
                }.padding(.horizontal, 14).frame(height: 26)
            }
        }
        .task {
            guard let ssh = model.ssh else { return }
            while !Task.isCancelled {
                await ssh.load()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
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
