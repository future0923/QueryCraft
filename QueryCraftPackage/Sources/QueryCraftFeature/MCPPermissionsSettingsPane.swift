import AppKit
import SwiftUI

/// Retain native grouped forms, just as the database detail tab host does.
/// Replacing all Form sections on every selection rebuilt every native control.
struct MCPPermissionsSettingsPane: NSViewRepresentable {
    let model: MCPSettingsModel
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTabView {
        let tabs = NSTabView()
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        update(tabs, coordinator: context.coordinator)
        return tabs
    }

    func updateNSView(_ tabs: NSTabView, context: Context) {
        update(tabs, coordinator: context.coordinator)
    }

    private func update(_ tabs: NSTabView, coordinator: Coordinator) {
        coordinator.select(model.authorizationStep, model: model, isEnabled: isEnabled,
                           colorScheme: colorScheme, in: tabs)
    }

    @MainActor final class Coordinator {
        private var pages: [String: NSHostingView<MCPPermissionForm>] = [:]
        private var model: MCPSettingsModel?
        private var isEnabled: Bool?
        private var colorScheme: ColorScheme?

        fileprivate func select(_ requestedStep: String, model: MCPSettingsModel, isEnabled: Bool,
                                colorScheme: ColorScheme, in tabs: NSTabView) {
            let step = ["connections", "databases", "overrides", "tools"].contains(requestedStep) ? requestedStep : "tools"
            if self.model !== model {
                for item in tabs.tabViewItems { tabs.removeTabViewItem(item) }
                pages.removeAll()
            }
            if self.model !== model || self.isEnabled != isEnabled || self.colorScheme != colorScheme {
                for (key, host) in pages {
                    host.rootView = MCPPermissionForm(model: model, step: key, isEnabled: isEnabled, colorScheme: colorScheme)
                }
                self.model = model
                self.isEnabled = isEnabled
                self.colorScheme = colorScheme
            }
            if pages[step] == nil {
                let host = NSHostingView(rootView: MCPPermissionForm(model: model, step: step,
                    isEnabled: isEnabled, colorScheme: colorScheme))
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                let item = NSTabViewItem(identifier: step)
                item.view = host
                pages[step] = host
                tabs.addTabViewItem(item)
            }
            guard tabs.selectedTabViewItem?.identifier as? String != step else { return }
            // A field editor from the old page must not keep receiving keystrokes.
            tabs.window?.makeFirstResponder(nil)
            tabs.selectTabViewItem(withIdentifier: step)
        }
    }
}

private struct MCPPermissionForm: View {
    let model: MCPSettingsModel
    let step: String
    let isEnabled: Bool
    let colorScheme: ColorScheme

    var body: some View {
        Form { MCPPermissionsSettingsSections(model: model, step: step) }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .font(MCPSettingsType.body)
            .controlSize(.regular)
            .environment(\.colorScheme, colorScheme)
            .disabled(!isEnabled)
    }
}
