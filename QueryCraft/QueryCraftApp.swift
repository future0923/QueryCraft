import SwiftUI
import QueryCraftFeature

@main
struct QueryCraftApp: App {
    @NSApplicationDelegateAdaptor(QueryCraftApplicationDelegate.self)
    private var applicationDelegate
    @State private var preferences = ApplicationPreferences.shared
    @ObservedObject private var softwareUpdateManager =
        SoftwareUpdateManager.shared

    var body: some Scene {
        Window("QueryCraft", id: "querycraft-welcome") {
            ContentView()
                .environment(\.locale, preferences.interfaceLocale)
                .background(WelcomeWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 740, height: 460)
        .windowResizability(.automatic)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(
                    String(localized: "Check for Updates..."),
                    action: softwareUpdateManager.checkForUpdates
                )
                .disabled(!softwareUpdateManager.canCheckForUpdates)
            }
            CommandGroup(replacing: .appSettings) {
                Button(
                    String(localized: "Settings..."),
                    systemImage: "gearshape",
                    action: SettingsWindowController.show
                )
                .keyboardShortcut(",", modifiers: .command)
            }
            WorkspaceQueryCommands()
            WorkspaceContentTabCommands()
            WorkspacePendingChangesCommands()
            WorkspaceDatabaseCommands()
            WorkspaceDatabaseObjectDetailTabCommands()
            WorkspaceGridSearchCommands()
            WorkspaceDataExportCommands()
            WorkspaceDatabaseDataFilterCommands()
        }
    }
}
