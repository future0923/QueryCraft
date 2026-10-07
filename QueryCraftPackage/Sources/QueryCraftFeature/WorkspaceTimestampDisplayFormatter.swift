import Foundation

enum WorkspaceTimestampDisplayMode: Int, CaseIterable {
    case automatic, raw, seconds, milliseconds

    var title: String {
        switch self {
        case .automatic: AppCopy.current.text("自动识别时间戳", "Automatic Timestamp")
        case .raw: AppCopy.current.text("原始值", "Raw Value")
        case .seconds: AppCopy.current.text("Unix 时间戳（秒）", "Unix Timestamp (Seconds)")
        case .milliseconds: AppCopy.current.text("Unix 时间戳（毫秒）", "Unix Timestamp (Milliseconds)")
        }
    }
}

/// Only the grid presentation uses this formatter. Editing, copying and exporting
/// continue to use the original cells, including their full numeric precision.
@MainActor
final class WorkspaceTimestampDisplayFormatter {
    static let shared = WorkspaceTimestampDisplayFormatter()

    private let formatter: DateFormatter
    private let cache = NSCache<NSString, NSString>()
    private let fixedTimeZone: TimeZone?
    private var timeZone: TimeZone

    init(timeZone: TimeZone? = nil) {
        fixedTimeZone = timeZone
        self.timeZone = timeZone ?? .current
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = self.timeZone
        cache.countLimit = 4_096
    }

    func preview(
        _ cell: WorkspaceDatabaseDataCell,
        column: WorkspaceDatabaseDataColumn?,
        mode: WorkspaceTimestampDisplayMode = .automatic,
        nullDisplayText: String = "NULL",
        emptyStringDisplayText: String = "",
        maximumCharacterCount: Int
    ) -> String {
        if let column, case let .text(raw) = cell,
           let formatted = timestamp(raw, column: column, mode: mode) {
            return WorkspaceDatabaseDataCell.boundedPreview(
                formatted, maximumCharacterCount: maximumCharacterCount
            )
        }
        return cell.gridPreviewText(
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            maximumCharacterCount: maximumCharacterCount
        )
    }

    func timestamp(
        _ raw: String,
        column: WorkspaceDatabaseDataColumn,
        mode: WorkspaceTimestampDisplayMode = .automatic
    ) -> String? {
        guard mode != .raw else { return nil }
        if mode == .automatic, !Self.hasTimestampHint(column) { return nil }
        // Bound parsing work even for multi-megabyte JSON or binary previews.
        let bytes = Array(raw.utf8.prefix(21))
        guard !bytes.isEmpty, bytes.count <= 20 else { return nil }
        let digits = bytes.first == 45 ? bytes.dropFirst() : bytes[...]
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(raw) else { return nil }
        let seconds: Double
        switch mode {
        case .raw: return nil
        case .seconds: seconds = Double(value)
        case .milliseconds: seconds = Double(value) / 1_000
        case .automatic:
            if (946_684_800..<4_102_444_800).contains(value) {
                seconds = Double(value)
            } else if (946_684_800_000..<4_102_444_800_000).contains(value) {
                seconds = Double(value) / 1_000
            } else {
                return nil
            }
        }
        // Keep explicit formats useful for historical dates and the Unix epoch,
        // while rejecting numbers outside the four-digit-year date range.
        guard seconds >= -62_135_596_800, seconds < 253_402_300_800 else { return nil }
        let currentTimeZone = fixedTimeZone ?? .current
        if currentTimeZone != timeZone {
            timeZone = currentTimeZone
            formatter.timeZone = timeZone
            cache.removeAllObjects()
        }
        let key = String(floor(seconds)) as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let text = formatter.string(from: Date(timeIntervalSince1970: seconds))
        cache.setObject(text as NSString, forKey: key)
        return text
    }

    static func hasTimestampHint(_ column: WorkspaceDatabaseDataColumn) -> Bool {
        let type = column.type?.lowercased() ?? ""
        let numericOrDate = type.isEmpty || type.contains("int")
            || ["long", "number", "numeric", "decimal", "date", "timestamp"].contains {
                type.hasPrefix($0)
            }
        guard numericOrDate else { return false }
        return [column.name, column.sourceColumnName].contains { name in
            let lower = name.lowercased()
            return ["timestamp", "@timestamp", "time", "created", "updated", "modified"].contains(lower)
                || ["_at", "_time", "_timestamp", ".timestamp", ".time"].contains { lower.hasSuffix($0) }
                || ["At", "Time", "Timestamp"].contains { name.hasSuffix($0) }
        }
    }
}
