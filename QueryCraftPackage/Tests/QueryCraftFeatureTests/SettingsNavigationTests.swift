import Testing
@testable import QueryCraftFeature

@MainActor
struct SettingsNavigationTests {
    @Test
    func exposesCurrentSettingsWithoutLicenseSettings() {
        #expect(!SettingsTab.visibleCases.contains(.license))
        #expect(SettingsTab.visibleCases.contains(.appearance))
        #expect(SettingsTab.visibleCases.contains(.plugins))
        #expect(SettingsTab.plugins.systemImage == "puzzlepiece.extension")
        #expect(ApplicationAppearance.allCases == [.system, .light, .dark])
    }

    @Test
    func redirectsLegacyLicenseNavigationToGeneralSettings() {
        let navigation = SettingsNavigation(selectedTab: .license)

        #expect(navigation.selectedTab == .general)
        #expect(!navigation.canGoBack)
        #expect(!navigation.canGoForward)

        navigation.selectedTab = .appearance
        navigation.selectedTab = .license
        #expect(navigation.selectedTab == .general)
    }

    @Test
    func movesBackwardAndForwardThroughVisitedTabs() {
        let navigation = SettingsNavigation()

        navigation.selectedTab = .editor
        navigation.selectedTab = .data

        #expect(navigation.canGoBack)
        #expect(!navigation.canGoForward)

        navigation.goBack()
        #expect(navigation.selectedTab == .editor)
        #expect(navigation.canGoBack)
        #expect(navigation.canGoForward)

        navigation.goBack()
        #expect(navigation.selectedTab == .general)
        #expect(!navigation.canGoBack)
        #expect(navigation.canGoForward)

        navigation.goForward()
        #expect(navigation.selectedTab == .editor)
    }

    @Test
    func selectingAfterGoingBackDiscardsForwardHistory() {
        let navigation = SettingsNavigation()
        navigation.selectedTab = .editor
        navigation.selectedTab = .data
        navigation.goBack()

        navigation.selectedTab = .general

        #expect(navigation.selectedTab == .general)
        #expect(!navigation.canGoForward)
    }
}
