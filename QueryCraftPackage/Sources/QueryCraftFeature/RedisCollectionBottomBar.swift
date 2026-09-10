import SwiftUI

struct RedisCollectionBottomBar: View {
    let details: RedisKeyDetails
    @Bindable var editor: RedisKeyEditorState
    @Bindable var searchState: RedisCollectionRemoteSearchState
    @Binding var sortOrder: RedisCollectionSortOrder
    let isEnabled: Bool
    let isLoading: Bool
    let loadMore: @MainActor @Sendable () -> Void
    let loadAll: @MainActor @Sendable () -> Void
    let cancelLoad: @MainActor @Sendable () -> Void
    let sortChanged: @MainActor @Sendable () -> Void

    var body: some View {
        ZStack {
            Text(statusText)
                .monospacedDigit()
                .lineLimit(1)

            HStack(spacing: 10) {
                if details.reference.type == .sortedSet {
                    Picker("", selection: $sortOrder) {
                        Text(AppCopy.current.text("降序", "DESC"))
                            .tag(RedisCollectionSortOrder.descending)
                        Text(AppCopy.current.text("升序", "ASC"))
                            .tag(RedisCollectionSortOrder.ascending)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                    .disabled(!isEnabled || isLoading)
                    .onChange(of: sortOrder) { _, _ in sortChanged() }
                }

                Text(metadataText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(metadataText)

                Spacer()

                HStack(spacing: 8) {
                    ZStack {
                        if isLoading {
                            WorkspaceInlineIconButton(
                                systemImageName: "stop.fill",
                                title: AppCopy.current.text(
                                    "停止加载",
                                    "Stop Loading"
                                ),
                                isEnabled: true,
                                action: cancelLoad
                            )
                        } else {
                            RedisCollectionValueLoadControls(
                                isEnabled: canLoadMoreValues,
                                loadMore: loadMore,
                                loadAll: loadAll
                            )
                        }
                    }
                    .frame(width: RedisCollectionValueLoadControls.width)

                    WorkspaceSearchControl(
                        isPresented: searchState.isPresented,
                        isEnabled: isEnabled && !isLoading,
                        togglePresentation: searchState.togglePresentation
                    )
                }
                .foregroundStyle(.primary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
        .accessibilityIdentifier("redisCollectionBottomBar")
    }

    private var canLoadMoreValues: Bool {
        isEnabled && editor.canLoadMoreCollectionRows
    }

    private var statusText: String {
        if searchState.submittedSearch != nil {
            if let matching = editor.collectionMatchingCount {
                return AppCopy.current.text(
                    "共 \(matching.formatted()) 个结果",
                    "\(matching.formatted()) results"
                )
            }
            return AppCopy.current.text(
                "\(editor.rows.count.formatted()) 个结果 · 已扫描 \(editor.collectionScannedCount.formatted()) / \((editor.collectionTotalCount ?? 0).formatted())",
                "\(editor.rows.count.formatted()) results · scanned \(editor.collectionScannedCount.formatted()) / \((editor.collectionTotalCount ?? 0).formatted())"
            )
        }
        return AppCopy.current.text(
            "已加载 \(editor.rows.count.formatted()) / 共 \((editor.collectionTotalCount ?? editor.rows.count).formatted())",
            "Loaded \(editor.rows.count.formatted()) of \((editor.collectionTotalCount ?? editor.rows.count).formatted())"
        )
    }

    private var metadataText: String {
        let memory = details.memoryUsageBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory)
        } ?? AppCopy.current.text("未知", "Unknown")
        return AppCopy.current.text("内存 \(memory)", "Memory \(memory)")
    }
}
