import Foundation

/// A SQL calendar value is a wall clock, not an instant in the Mac's time zone.
/// Use UTC solely as a container for the components shown by NSDatePicker.
struct WorkspaceSQLDateType: Equatable, Sendable {
    let includesDate: Bool
    let includesTime: Bool
    let includesTimeZone: Bool
    let fractionalPrecision: Int?

    init?(_ type: String?) {
        guard let type else { return nil }
        let normalized = type.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(date|datev2|time|datetime|datetimev2|timestamp|timestamptz)(?:\(([0-6])\))?(?: (with|without) time zone)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: normalized).map { String(normalized[$0]) }
        }
        let name = group(1)
        includesDate = name != "time"
        includesTime = name != "date" && name != "datev2"
        includesTimeZone = name == "timestamptz" || group(3) == "with"
        // MySQL/Doris declarations without (p) default to whole seconds.
        // PostgreSQL format_type includes "with/without time zone" and defaults to 6.
        fractionalPrecision = group(2).flatMap(Int.init)
            ?? (name == "datetime" || name == "datetimev2" || name == "time" || (name == "timestamp" && group(3) == nil) ? 0 : nil)
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func parse(_ text: String) -> WorkspaceSQLDateValue? {
        let pattern = includesDate
            ? (includesTime
                ? #"^(\d{4})-(\d{2})-(\d{2})([ T])(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}(?::?\d{2})?(?::?\d{2})?)?$"#
                : #"^(\d{4})-(\d{2})-(\d{2})$"#)
            : #"^(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}(?::?\d{2})?(?::?\d{2})?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text)
        else { return nil }
        func group(_ index: Int) -> String? {
            guard index < match.numberOfRanges else { return nil }
            return Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        let hourGroup = includesDate ? 5 : 1
        let minuteGroup = includesDate ? 6 : 2
        let secondGroup = includesDate ? 7 : 3
        let fractionGroup = includesDate ? 8 : 4
        let suffixGroup = includesDate ? 9 : 5
        let components = DateComponents(
            year: includesDate ? group(1).flatMap(Int.init) : 2000,
            month: includesDate ? group(2).flatMap(Int.init) : 1,
            day: includesDate ? group(3).flatMap(Int.init) : 1,
            hour: group(hourGroup).flatMap(Int.init) ?? 0,
            minute: group(minuteGroup).flatMap(Int.init) ?? 0,
            second: group(secondGroup).flatMap(Int.init) ?? 0
        )
        guard let year = components.year, (1...9999).contains(year),
              let date = Self.calendar.date(from: components),
              Self.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components
        else { return nil }
        let fraction = group(fractionGroup) ?? ""
        let suffix = group(suffixGroup) ?? ""
        guard fraction.count <= (fractionalPrecision ?? 6),
              suffix.isEmpty || (includesTimeZone && WorkspaceSQLDateValue.offsetSeconds(suffix) != nil)
        else { return nil }
        return WorkspaceSQLDateValue(date: date, fraction: fraction, separator: group(4) ?? " ", zoneSuffix: suffix)
    }

    func seed(now: Date = .now, timeZone: TimeZone = .current) -> WorkspaceSQLDateValue {
        let offset = timeZone.secondsFromGMT(for: now)
        let suffix = includesTimeZone ? String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60) : ""
        return WorkspaceSQLDateValue(
            date: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + Double(offset)),
            fraction: String(repeating: "0", count: fractionalPrecision ?? 0),
            separator: " ", zoneSuffix: suffix
        )
    }

    func string(for value: WorkspaceSQLDateValue) -> String? {
        guard value.fraction.count <= (fractionalPrecision ?? 6),
              value.fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let parts = Self.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value.date)
        guard let year = parts.year, (1...9999).contains(year) else { return nil }
        let time = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let timeValue = time + (value.fraction.isEmpty ? "" : "." + value.fraction) + value.zoneSuffix
        guard includesDate else { return timeValue }
        let date = String(format: "%04d-%02d-%02d", year, parts.month ?? 1, parts.day ?? 1)
        guard includesTime else { return date }
        return date + value.separator + timeValue
    }
}

struct WorkspaceSQLDateValue: Equatable, Sendable {
    var date: Date
    var fraction: String
    var separator: String
    var zoneSuffix: String

    static func offsetSeconds(_ suffix: String) -> Int? {
        if suffix == "Z" { return 0 }
        guard suffix.first == "+" || suffix.first == "-" else { return nil }
        let digits = suffix.dropFirst().replacingOccurrences(of: ":", with: "")
        guard [2, 4, 6].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let hours = Int(digits.prefix(2)), hours <= 15 else { return nil }
        let minutes = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 60 : 0
        let seconds = digits.count == 6 ? Int(digits.suffix(2)) ?? 60 : 0
        guard minutes < 60, seconds < 60 else { return nil }
        return (hours * 3600 + minutes * 60 + seconds) * (suffix.first == "-" ? -1 : 1)
    }
}
