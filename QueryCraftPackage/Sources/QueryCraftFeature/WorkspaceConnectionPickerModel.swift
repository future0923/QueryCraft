import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceConnectionPickerModel: Identifiable {
    typealias ProfileLoader = @MainActor () async throws -> [ConnectionProfile]

    let id = UUID()
    let currentProfileID: ConnectionProfile.ID
    var searchText = "" {
        didSet { synchronizeSelection() }
    }
    var selectionID: ConnectionProfile.ID?
    private(set) var profiles: [ConnectionProfile] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    @ObservationIgnored
    private let loadProfiles: ProfileLoader

    init(
        currentProfileID: ConnectionProfile.ID,
        loadProfiles: @escaping ProfileLoader
    ) {
        self.currentProfileID = currentProfileID
        self.loadProfiles = loadProfiles
    }

    var filteredProfiles: [ConnectionProfile] {
        guard !searchText.isEmpty else { return profiles }
        return profiles.filter { profile in
            profile.name.localizedStandardContains(searchText)
                || endpoint(for: profile).localizedStandardContains(searchText)
        }
    }

    var selectedProfile: ConnectionProfile? {
        guard let selectionID else { return nil }
        return profiles.first { $0.id == selectionID }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            profiles = try await loadProfiles()
            try Task.checkCancellation()
            synchronizeSelection()
        } catch is CancellationError {
            return
        } catch {
            profiles = []
            selectionID = nil
            errorMessage = error.localizedDescription
        }
    }

    func moveSelection(by offset: Int) {
        let visibleProfiles = filteredProfiles
        guard !visibleProfiles.isEmpty else { return }

        let currentIndex = selectionID.flatMap { selectionID in
            visibleProfiles.firstIndex { $0.id == selectionID }
        }
        let proposedIndex: Int
        if let currentIndex {
            proposedIndex = currentIndex + offset
        } else {
            proposedIndex = offset < 0 ? visibleProfiles.count - 1 : 0
        }
        let index = min(max(proposedIndex, 0), visibleProfiles.count - 1)
        selectionID = visibleProfiles[index].id
    }

    func endpoint(for profile: ConnectionProfile) -> String {
        "\(profile.username)@\(profile.host):\(profile.port)"
    }

    private func synchronizeSelection() {
        let visibleProfiles = filteredProfiles
        if let selectionID,
           visibleProfiles.contains(where: { $0.id == selectionID })
        {
            return
        }
        if visibleProfiles.contains(where: { $0.id == currentProfileID }) {
            selectionID = currentProfileID
        } else {
            selectionID = visibleProfiles.first?.id
        }
    }
}
