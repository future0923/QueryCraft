import SwiftUI

struct DatabaseDriverSelectionList: View {
    @Bindable var model: NewConnectionFlowModel
    var body: some View {
        List(selection: $model.selectedConnection) {
            ForEach(model.visibleItems) { item in
                DatabaseDriverSelectionRow(item: item, isSelected: !model.selectsSSH && model.selectedDatabaseProduct == item.entry.databaseProduct)
                    .tag(NewConnectionFlowModel.ConnectionChoice.database(item.entry.databaseProduct))
                    .accessibilityIdentifier("databaseProduct.\(item.entry.databaseProduct.rawValue)")
            }
            if model.matchesSSH {
                ConnectionTypeSelectionRow(title: "SSH",
                    subtitle: AppCopy.current.text("交互式终端与远程命令", "Interactive terminal and remote commands"),
                    state: ConnectionPluginPresentation(model.sshPlugin).installationState) {
                        ConnectionPluginIcon(databaseType: nil)
                    }
                    .tag(NewConnectionFlowModel.ConnectionChoice.ssh)
                    .accessibilityIdentifier("connectionType.ssh")
            }
        }.listStyle(.inset)
            .overlay {
                if !model.catalogLoaded { ProgressView().controlSize(.small).allowsHitTesting(false) }
                else if model.visibleItems.isEmpty && !model.matchesSSH { ContentUnavailableView.search(text: model.searchText) }
            }
    }
}
