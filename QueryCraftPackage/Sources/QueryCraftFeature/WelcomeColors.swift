import SwiftUI

extension Color {
    static let welcomePrimaryPane = Color(nsColor: NSColor(name: "WelcomePrimaryPane") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .windowBackgroundColor
    })
    static let welcomeSecondaryPane = Color(nsColor: NSColor(name: "WelcomeSecondaryPane") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .controlBackgroundColor
    })
}
