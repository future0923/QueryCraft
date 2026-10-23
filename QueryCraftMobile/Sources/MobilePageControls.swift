import SwiftUI

/// Settings belong in the existing toolbar menu; paging shares the status footer.
struct MobilePageOptions: View {
    @Bindable var model: MobileBrowserModel
    var presentFilter: (() -> Void)?
    var body: some View {
        if let presentFilter {
            Button(model.dataFilter.isActive ? "编辑筛选（\(model.dataFilter.enabledConditions.count)）" : "筛选数据", systemImage: "line.3.horizontal.decrease.circle", action: presentFilter)
                .disabled(model.columns?.isEmpty != false)
        }
        Picker("每页行数", selection: $model.pageSize) {
            ForEach([25, 50, 100, 200], id: \.self) { Text("\($0) 行").tag($0) }
        }
        if let columns = model.columns {
            Menu("排序", systemImage: "arrow.up.arrow.down") {
                ForEach(columns) { col in
                    Button(col.name + (model.sortColumn == col.name ? (model.ascending ? " ↑" : " ↓") : "")) {
                        model.sort(by: col.name)
                    }
                }
            }
        }
    }
}

struct MobilePageNavigation: View {
    @Bindable var model: MobileBrowserModel
    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.loadTable(offset: max(0, (model.snapshot?.offset ?? 0) - (model.snapshot?.pageSize ?? model.pageSize)))
            } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
            .disabled(model.isLoadingTable || (model.snapshot?.offset ?? 0) == 0).accessibilityLabel("上一页")
            Text("\((model.snapshot?.offset ?? 0) / max(1, model.snapshot?.pageSize ?? 100) + 1)")
                .font(.caption.weight(.medium)).monospacedDigit().frame(minWidth: 24).accessibilityLabel("当前页")
            Button {
                model.loadTable(offset: (model.snapshot?.offset ?? 0) + (model.snapshot?.pageSize ?? model.pageSize))
            } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
            .disabled(model.isLoadingTable || model.snapshot?.hasNextPage != true).accessibilityLabel("下一页")
        }.buttonStyle(.plain).foregroundStyle(.primary).fixedSize()
    }
}
