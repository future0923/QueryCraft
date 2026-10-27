import SwiftUI

struct SettingsView: View {
    @Bindable var navigation: SettingsNavigation
    @State private var preferences = ApplicationPreferences.shared
    @State private var mcpModel = MCPSettingsModel()
    @State private var sshModel = SSHSettingsModel()
    let updateWindowTitle: (String) -> Void

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsTab.visibleCases, selection: $navigation.selectedTab) { tab in
                Label(copy.title(for: tab), systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .queryCraftCanvas))
            .modifier(SettingsSidebarScrollEdgeEffectModifier())
            .navigationTitle(copy.settings)
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(
                tab: navigation.selectedTab,
                preferences: preferences,
                mcpModel: mcpModel,
                sshModel: sshModel
            )
            .background(Color(nsColor: .queryCraftCanvas))
        }
        .navigationTitle(copy.settings)
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(Color(nsColor: .queryCraftCanvas), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .environment(\.locale, preferences.interfaceLocale)
        .onAppear {
            updateWindowTitle(copy.settings)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(
                    copy.back,
                    systemImage: "chevron.left",
                    action: navigation.goBack
                )
                .labelStyle(.iconOnly)
                .disabled(!navigation.canGoBack)

                Button(
                    copy.forward,
                    systemImage: "chevron.right",
                    action: navigation.goForward
                )
                .labelStyle(.iconOnly)
                .disabled(!navigation.canGoForward)
            }
        }
    }
}
