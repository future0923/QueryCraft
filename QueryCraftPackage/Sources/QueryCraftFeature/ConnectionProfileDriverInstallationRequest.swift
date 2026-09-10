import AppKit

struct ConnectionProfileDriverInstallationRequest: Identifiable {
    let profile: ConnectionProfile
    let welcomeWindow: NSWindow?

    var id: ConnectionProfile.ID { profile.id }
}
