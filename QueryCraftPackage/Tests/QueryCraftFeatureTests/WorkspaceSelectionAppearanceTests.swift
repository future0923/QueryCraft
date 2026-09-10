import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

struct WorkspaceSelectionAppearanceTests {
    @Test @MainActor
    func selectionUsesARestrainedSystemGrayBackground() {
        #expect(
            WorkspaceSelectionAppearance.backgroundColor
                == .unemphasizedSelectedContentBackgroundColor
        )
        #expect(
            WorkspaceSelectionAppearance.backgroundColor
                != .selectedContentBackgroundColor
        )
    }

    @Test @MainActor
    func databaseRailUsesMoreSeparationInLightAppearance() {
        #expect(
            WorkspaceDatabaseRail.backgroundSeparationOpacity(for: .light)
                == 0.08
        )
        #expect(
            WorkspaceDatabaseRail.backgroundSeparationOpacity(for: .dark)
                == 0.05
        )
    }
}
