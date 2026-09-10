import Foundation
import SwiftUI

struct RedisKeyInspectorMetadataList: View {
    let details: RedisKeyDetails
    let searchText: String

    var body: some View {
        let keyItems = keyInformation.filter(matchesSearch)
        let sizeItems = sizeInformation.filter(matchesSearch)

        List {
            if !keyItems.isEmpty {
                Section {
                    ForEach(keyItems) { item in
                        RedisKeyInspectorMetadataRow(item: item)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(AppCopy.current.text("Key 信息", "KEY"))
                }
            }

            if !sizeItems.isEmpty {
                Section {
                    ForEach(sizeItems) { item in
                        RedisKeyInspectorMetadataRow(item: item)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(AppCopy.current.text("大小", "SIZE"))
                }
            }

            if !searchText.isEmpty && keyItems.isEmpty && sizeItems.isEmpty {
                Text(
                    AppCopy.current.text(
                        "没有匹配的 Key 信息",
                        "No matching key information"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("redisKeyInspector")
    }

    private var keyInformation: [WorkspaceRedisKeyInspectorItem] {
        [
            WorkspaceRedisKeyInspectorItem(
                id: "type",
                label: AppCopy.current.text("类型", "Type"),
                value: details.reference.type.rawValue
            ),
            WorkspaceRedisKeyInspectorItem(
                id: "ttl",
                label: "TTL",
                value: expiration
            ),
            WorkspaceRedisKeyInspectorItem(
                id: "encoding",
                label: AppCopy.current.text("编码", "Encoding"),
                value: formatMetadata(details.encoding)
            ),
        ]
    }

    private var sizeInformation: [WorkspaceRedisKeyInspectorItem] {
        [
            WorkspaceRedisKeyInspectorItem(
                id: "memory",
                label: AppCopy.current.text("内存", "Memory"),
                value: memoryUsage
            ),
            WorkspaceRedisKeyInspectorItem(
                id: "value",
                label: AppCopy.current.text("值", "Value"),
                value: valueMetric
            ),
        ]
    }

    private var expiration: String {
        guard let milliseconds = details.ttlMilliseconds else {
            return AppCopy.current.text("永不过期", "No expiration")
        }
        return Duration.milliseconds(milliseconds).formatted(.units())
    }

    private var memoryUsage: String {
        guard let bytes = details.memoryUsageBytes else {
            return AppCopy.current.text("不可用", "Unavailable")
        }
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .memory
        )
    }

    private var valueMetric: String {
        switch details.reference.type {
        case .string:
            guard let value = details.value.rows.first?.first else {
                return AppCopy.current.text("不可用", "Unavailable")
            }
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(value.utf8.count),
                countStyle: .memory
            )
            return details.value.isTruncated ? "≥ \(size)" : size
        case .list, .set, .sortedSet, .hash, .stream:
            let count = details.value.rows.count.formatted()
            return AppCopy.current.text(
                details.value.isTruncated
                    ? "\(count)+ 个元素"
                    : "\(count) 个元素",
                details.value.isTruncated
                    ? "\(count)+ elements"
                    : "\(count) elements"
            )
        case .module, .none, .unknown:
            return AppCopy.current.text("不可用", "Unavailable")
        }
    }

    private func matchesSearch(
        _ item: WorkspaceRedisKeyInspectorItem
    ) -> Bool {
        searchText.isEmpty
            || item.label.localizedStandardContains(searchText)
            || item.value.localizedStandardContains(searchText)
    }

    private func formatMetadata(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return AppCopy.current.text("不可用", "Unavailable")
        }
        return value
    }
}
