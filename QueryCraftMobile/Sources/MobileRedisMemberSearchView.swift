import SwiftUI
import QueryCraftMobileCore

struct MobileRedisMemberSearchView: View {
    @Bindable var editor: MobileRedisEditor
    @Bindable var state: RedisCollectionRemoteSearchState
    let type: RedisKeyType
    var body: some View {
        Section {
            DisclosureGroup("成员搜索", isExpanded: $state.isPresented) {
                Group {
                    TextField("在整个键中搜索", text: $state.draftText).submitLabel(.search)
                        .onSubmit { editor.applySearch() }.accessibilityIdentifier("redisMemberSearchText")
                    Picker("范围", selection: $state.field) {
                        ForEach(state.availableFields(for: type), id: \.self) { Text(title($0)).tag($0) }
                    }
                    Picker("匹配", selection: $state.mode) {
                        Text("包含").tag(RedisCollectionMatchMode.contains)
                        Text("前缀").tag(RedisCollectionMatchMode.prefix)
                        Text("精确").tag(RedisCollectionMatchMode.exact)
                    }
                    Toggle("区分大小写", isOn: $state.isCaseSensitive)
                    HStack {
                        Button("搜索整个键") { editor.applySearch() }.accessibilityIdentifier("redisMemberSearchSubmit")
                        Spacer()
                        Button("清除搜索") { editor.applySearch(clear: true) }
                    }
                }.disabled(!editor.canSearch)
                if editor.hasChanges { Text("先提交或丢弃草稿，再切换搜索。").font(.caption).foregroundStyle(.secondary) }
            }
            Text(editor.activeSearch.map { "当前显示：" + $0.text } ?? "当前显示：全部成员")
                .font(.caption).foregroundStyle(.secondary)
            if editor.isSearchPending { Text("搜索尚未完成，保留上次结果；可重试或清除搜索。").font(.caption).foregroundStyle(.secondary) }
            if editor.activeSearch != nil, let snapshot = editor.snapshot {
                Text(snapshot.matchingCount.map { "匹配 \($0) 项" } ?? "扫描尚未结束，继续读取可获取更多匹配项")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func title(_ field: RedisCollectionSearchField) -> String {
        switch field {
        case .all: "全部"
        case .value: "值"
        case .field: "字段"
        case .member: "成员"
        case .score: "分数"
        }
    }
}
