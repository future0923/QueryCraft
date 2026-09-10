import Foundation
import SwiftUI

struct RedisKeyMetadataBar: View {
    let details: RedisKeyDetails?
    let searchController: WorkspaceGridSearchController?

    var body: some View {
        ZStack {
            Text(details == nil ? "" : valueMetric)
                .lineLimit(1)
                .monospacedDigit()
                .help(valueHelp)

            HStack(spacing: 12) {
                Text(details == nil ? "" : leadingSummary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(leadingHelp)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                if let searchController {
                    WorkspaceGridSearchControl(
                        controller: searchController
                    )
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHidden(details == nil)
        .accessibilityIdentifier("redisKeyMetadataBar")
    }

    private var leadingSummary: String {
        "\(keyType) · \(expiration) · \(memoryUsage) · \(encoding)"
    }

    private var keyType: String {
        details?.reference.type.rawValue ?? "--"
    }

    private var encoding: String {
        details?.encoding ?? "--"
    }

    private var leadingHelp: String {
        AppCopy.current.text(
            "类型 \(keyType)，TTL \(expiration)，内存 \(memoryUsage)，编码 \(encoding)",
            "Type \(keyType), TTL \(expiration), memory \(memoryUsage), encoding \(encoding)"
        )
    }

    private var valueHelp: String {
        AppCopy.current.text(
            "值 \(valueMetric)",
            "Value \(valueMetric)"
        )
    }

    private var encodingHelp: String {
        AppCopy.current.text(
            "编码 \(encoding)",
            "Encoding \(encoding)"
        )
    }

    private var accessibilitySummary: String {
        AppCopy.current.text(
            "\(leadingHelp)，\(valueHelp)",
            "\(leadingHelp), \(valueHelp)"
        )
    }

    private var expiration: String {
        guard let details else { return "--" }
        guard let milliseconds = details.ttlMilliseconds else {
            return AppCopy.current.text("永不过期", "No expiration")
        }
        return Duration.milliseconds(milliseconds).formatted(.units())
    }

    private var memoryUsage: String {
        guard let details else { return "--" }
        guard let bytes = details.memoryUsageBytes else {
            return AppCopy.current.text("未知", "Unknown")
        }
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .memory
        )
    }

    private var valueMetric: String {
        guard let details else { return "--" }
        switch details.reference.type {
        case .string:
            guard let value = details.value.rows.first?.first else {
                return "--"
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
            return "--"
        }
    }
}
