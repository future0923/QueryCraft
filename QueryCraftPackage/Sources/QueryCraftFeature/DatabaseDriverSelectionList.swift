import SwiftUI

struct DatabaseDriverSelectionList: View {
    @Bindable var model: NewConnectionFlowModel

    var body: some View {
        if model.catalogItems.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleItems.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            List(selection: $model.selectedDatabaseProduct) {
                ForEach(DatabaseDriverCatalogEntry.Category.allCases, id: \.self) { category in
                    let items = model.visibleItems.filter {
                        $0.driverItem.entry.category == category
                    }
                    if !items.isEmpty {
                        Section(category.title) {
                            ForEach(items) { item in
                                DatabaseDriverSelectionRow(
                                    item: item,
                                    isSelected:
                                        model.selectedDatabaseProduct
                                            == item.entry.databaseProduct
                                )
                                .tag(item.entry.databaseProduct)
                                .accessibilityIdentifier(
                                    "databaseProduct.\(item.entry.databaseProduct.rawValue)"
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
