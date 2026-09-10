import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceConnectionPickerModelTests {
    @Test
    func startsLoadingBeforeProfilesArePrepared() {
        let model = WorkspaceConnectionPickerModel(
            currentProfileID: UUID(),
            loadProfiles: { [] }
        )

        #expect(model.isLoading)
        #expect(model.profiles.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test
    func loadSelectsCurrentProfileAndSearchesNameAndEndpoint() async {
        let current = makeProfile(
            name: "Production",
            host: "prod.internal",
            username: "reader"
        )
        let staging = makeProfile(
            name: "Staging",
            host: "staging.internal",
            username: "writer"
        )
        let model = WorkspaceConnectionPickerModel(
            currentProfileID: current.id,
            loadProfiles: { [staging, current] }
        )

        await model.load()

        #expect(model.selectionID == current.id)
        #expect(model.selectedProfile == current)

        model.searchText = "Staging"
        #expect(model.filteredProfiles == [staging])
        #expect(model.selectionID == staging.id)

        model.searchText = "reader@prod.internal:3306"
        #expect(model.filteredProfiles == [current])
        #expect(model.selectionID == current.id)
    }

    @Test
    func keyboardMovementStaysWithinFilteredProfiles() async {
        let first = makeProfile(name: "Alpha", host: "alpha.internal")
        let second = makeProfile(name: "Beta", host: "beta.internal")
        let third = makeProfile(name: "Gamma", host: "gamma.internal")
        let model = WorkspaceConnectionPickerModel(
            currentProfileID: second.id,
            loadProfiles: { [first, second, third] }
        )

        await model.load()
        model.moveSelection(by: 1)
        #expect(model.selectionID == third.id)
        model.moveSelection(by: 1)
        #expect(model.selectionID == third.id)
        model.moveSelection(by: -1)
        #expect(model.selectionID == second.id)

        model.searchText = "alpha"
        #expect(model.selectionID == first.id)
        model.moveSelection(by: -1)
        #expect(model.selectionID == first.id)
    }

    @Test
    func loadFailureClearsSelectionAndExposesMessage() async {
        let model = WorkspaceConnectionPickerModel(
            currentProfileID: UUID(),
            loadProfiles: { throw PickerLoadError.failed }
        )

        await model.load()

        #expect(model.profiles.isEmpty)
        #expect(model.selectionID == nil)
        #expect(model.errorMessage == "Picker failed")
        #expect(!model.isLoading)
    }

    private func makeProfile(
        name: String,
        host: String,
        username: String = "root"
    ) -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: name,
            groupID: nil,
            host: host,
            port: 3306,
            username: username,
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
    }
}

private enum PickerLoadError: LocalizedError {
    case failed

    var errorDescription: String? { "Picker failed" }
}
