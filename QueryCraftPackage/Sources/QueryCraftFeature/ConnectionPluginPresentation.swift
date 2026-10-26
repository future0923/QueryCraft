import SwiftUI

/// Presentation shared by database and terminal plugins. Runtime APIs stay capability-specific.
struct ConnectionPluginPresentation {
    let databaseType: DatabaseType?
    let displayName: String
    let installationState: DatabaseDriverInstallationState
    let installedVersion: String?
    let availableVersion: String?
    let downloadSize: Int64?
    let availabilityErrorMessage: String?

    init(_ item: DatabaseDriverCatalogItem) {
        databaseType = item.entry.databaseType; displayName = item.entry.displayName
        installationState = item.installationState; installedVersion = item.installedVersion
        availableVersion = item.availableVersion; downloadSize = item.downloadSize
        availabilityErrorMessage = item.availabilityErrorMessage
    }

    @MainActor init(_ model: SSHPluginSettingsModel) {
        databaseType = nil; displayName = "SSH"
        installedVersion = model.installed; availableVersion = model.release?.version
        downloadSize = model.release?.size; availabilityErrorMessage = model.availabilityError
        if model.removing { installationState = .uninstalling }
        else if model.busy {
            let phase: DatabaseDriverInstallationPhase
            switch model.progress?.phase {
            case .downloading: phase = .downloading
            case .verifying, .selfTesting: phase = .verifying
            case .extracting, .installing, .finishing: phase = .installing
            default: phase = .checkingCompatibility
            }
            let progress = DatabaseDriverInstallationProgress(phase: phase,
                fractionCompleted: model.progress?.fractionCompleted, receivedBytes: model.progress?.receivedBytes,
                totalBytes: model.progress?.totalBytes, bytesPerSecond: model.progress?.bytesPerSecond)
            installationState = model.installed == nil ? .installing(progress) : .updating(progress)
        } else if let error = model.error { installationState = .failed(message: error) }
        else if let installed = model.installed {
            installationState = model.release.map { $0.version.compare(installed, options: .numeric) == .orderedDescending } == true
                ? .updateAvailable : .installed
        } else { installationState = .notInstalled }
    }
}

struct ConnectionPluginIcon: View {
    let databaseType: DatabaseType?
    var body: some View {
        if let databaseType { DatabaseBrandIcon(databaseType: databaseType) }
        else { Image(systemName: "terminal").font(.title2) }
    }
}
