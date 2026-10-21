import SwiftUI

struct WorkspaceTableActionMenu: View {
    let databaseType: DatabaseType
    let perform: @MainActor (WorkspaceTableAction) -> Void

    var body: some View {
        ForEach(WorkspaceTableAction.allCases) { action in
            Button(action.title + "…", role: action.isDestructive ? .destructive : nil) {
                perform(action)
            }
            .disabled(action.unavailabilityReason(for: databaseType) != nil)
            .help(action.unavailabilityReason(for: databaseType) ?? action.explanation(for: databaseType))
            .accessibilityIdentifier("tableAction.\(action.rawValue)")
        }
    }
}
