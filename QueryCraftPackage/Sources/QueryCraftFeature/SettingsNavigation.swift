import Observation

@MainActor
@Observable
final class SettingsNavigation {
    var selectedTab: SettingsTab {
        didSet {
            if selectedTab == .license {
                selectedTab = .general
                return
            }
            recordSelection()
        }
    }

    private(set) var canGoBack = false
    private(set) var canGoForward = false

    private var history: [SettingsTab]
    private var historyIndex: Int
    private var isNavigatingHistory = false

    init(selectedTab: SettingsTab = .general) {
        let initialTab = selectedTab == .license ? .general : selectedTab
        self.selectedTab = initialTab
        history = [initialTab]
        historyIndex = 0
    }

    func goBack() {
        guard canGoBack else { return }
        isNavigatingHistory = true
        historyIndex -= 1
        selectedTab = history[historyIndex]
        isNavigatingHistory = false
        updateNavigationAvailability()
    }

    func goForward() {
        guard canGoForward else { return }
        isNavigatingHistory = true
        historyIndex += 1
        selectedTab = history[historyIndex]
        isNavigatingHistory = false
        updateNavigationAvailability()
    }

    private func recordSelection() {
        guard !isNavigatingHistory else { return }
        guard history[historyIndex] != selectedTab else { return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        history.append(selectedTab)
        historyIndex = history.count - 1
        updateNavigationAvailability()
    }

    private func updateNavigationAvailability() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex < history.count - 1
    }
}
