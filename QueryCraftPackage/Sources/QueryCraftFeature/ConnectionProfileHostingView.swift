import AppKit
import SwiftUI

@MainActor
final class ConnectionProfileHostingView:
    NSHostingView<ConnectionProfileRow>
{
    private let profile: ConnectionProfile
    private var showsSelectedAppearance = false

    init(profile: ConnectionProfile) {
        self.profile = profile
        super.init(
            rootView: ConnectionProfileRow(profile: profile)
        )
    }

    @available(*, unavailable)
    required init(rootView: ConnectionProfileRow) {
        fatalError("Use init(profile:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelectedAppearance(_ isSelected: Bool) {
        guard showsSelectedAppearance != isSelected else { return }
        showsSelectedAppearance = isSelected
        rootView = ConnectionProfileRow(
            profile: profile,
            isSelected: isSelected
        )
    }
}
