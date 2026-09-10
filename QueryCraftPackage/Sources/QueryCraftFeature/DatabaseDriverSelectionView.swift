import SwiftUI

struct DatabaseDriverSelectionView: View {
    @Bindable var model: NewConnectionFlowModel
    let cancel: () -> Void
    let continueSelection: () -> Void
    let uninstallSelection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DatabaseDriverSelectionHeader(searchText: $model.searchText)
            Divider()
            DatabaseDriverSelectionList(model: model)
            Divider()
            DatabaseDriverSelectionFooter(
                model: model,
                cancel: cancel,
                continueSelection: continueSelection,
                uninstallSelection: uninstallSelection
            )
        }
        .frame(width: 620, height: 500)
        .accessibilityIdentifier("databaseDriverSelectionView")
    }
}
