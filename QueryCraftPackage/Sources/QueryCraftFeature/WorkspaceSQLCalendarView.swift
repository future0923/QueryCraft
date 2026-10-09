import Combine
import SwiftUI

@MainActor
final class WorkspaceSQLCalendarModel: ObservableObject {
    @Published var date: Date

    init(date: Date) {
        self.date = date
    }
}

@MainActor
final class WorkspaceSQLTimeEditingModel: ObservableObject {
    @Published var hourText: String
    @Published var minuteText: String
    @Published var secondText: String
    @Published var fractionText: String

    init(date: Date, fraction: String) {
        let calendar = WorkspaceSQLDateType.calendar
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        hourText = String(format: "%02d", components.hour ?? 0)
        minuteText = String(format: "%02d", components.minute ?? 0)
        secondText = String(format: "%02d", components.second ?? 0)
        fractionText = fraction
    }

    var hour: Int? { Int(hourText) }
    var minute: Int? { Int(minuteText) }
    var second: Int? { Int(secondText) }
    var isValid: Bool {
        guard let hour, let minute, let second,
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return false }
        return fractionText.allSatisfy(\.isNumber)
    }

    func sync(date: Date, fraction: String) {
        let calendar = WorkspaceSQLDateType.calendar
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        hourText = String(format: "%02d", components.hour ?? 0)
        minuteText = String(format: "%02d", components.minute ?? 0)
        secondText = String(format: "%02d", components.second ?? 0)
        fractionText = fraction
    }

    func adjust(_ component: Component, by amount: Int) {
        switch component {
        case .hour:
            hourText = String(format: "%02d", ((hour ?? 0) + amount + 24) % 24)
        case .minute:
            minuteText = String(format: "%02d", ((minute ?? 0) + amount + 60) % 60)
        case .second:
            secondText = String(format: "%02d", ((second ?? 0) + amount + 60) % 60)
        }
    }

    func normalize(_ component: Component) {
        switch component {
        case .hour:
            hourText = String(format: "%02d", min(max(hour ?? 0, 0), 23))
        case .minute:
            minuteText = String(format: "%02d", min(max(minute ?? 0, 0), 59))
        case .second:
            secondText = String(format: "%02d", min(max(second ?? 0, 0), 59))
        }
    }

    enum Component {
        case hour, minute, second
    }
}

@MainActor
final class WorkspaceSQLDateEditingModel: ObservableObject {
    @Published var yearText: String
    @Published var monthText: String
    @Published var dayText: String

    init(date: Date) {
        let calendar = WorkspaceSQLDateType.calendar
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        yearText = String(format: "%04d", components.year ?? 2000)
        monthText = String(format: "%02d", components.month ?? 1)
        dayText = String(format: "%02d", components.day ?? 1)
    }

    var year: Int? { Int(yearText) }
    var month: Int? { Int(monthText) }
    var day: Int? { Int(dayText) }
    var date: Date? {
        guard let year, let month, let day else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let calendar = WorkspaceSQLDateType.calendar
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components
        else { return nil }
        return date
    }

    var isValid: Bool { date != nil }

    func sync(date: Date) {
        let calendar = WorkspaceSQLDateType.calendar
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        yearText = String(format: "%04d", components.year ?? 2000)
        monthText = String(format: "%02d", components.month ?? 1)
        dayText = String(format: "%02d", components.day ?? 1)
    }

    func adjust(_ component: Component, by amount: Int) {
        guard let base = date else { return }
        let calendar = WorkspaceSQLDateType.calendar
        let unit: Calendar.Component = switch component {
        case .year: .year
        case .month: .month
        case .day: .day
        }
        if let adjusted = calendar.date(byAdding: unit, value: amount, to: base) {
            sync(date: adjusted)
        }
    }

    func normalize(_ component: Component) {
        switch component {
        case .year:
            yearText = String(format: "%04d", min(max(year ?? 1, 1), 9999))
        case .month:
            monthText = String(format: "%02d", min(max(month ?? 1, 1), 12))
        case .day:
            let maxDay = month.flatMap { month in
                year.flatMap { year in
                    WorkspaceSQLDateType.calendar.range(
                        of: .day,
                        in: .month,
                        for: WorkspaceSQLDateType.calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now
                    )?.count
                }
            } ?? 31
            dayText = String(format: "%02d", min(max(day ?? 1, 1), maxDay))
        }
    }

    enum Component {
        case year, month, day
    }
}

struct WorkspaceSQLDateEditorView: View {
    @ObservedObject var model: WorkspaceSQLDateEditingModel
    let onChange: (Date) -> Void
    let onValidityChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 5) {
            component(.year, text: $model.yearText, placeholder: "年", width: 54, label: "年份")
            separator
            component(.month, text: $model.monthText, placeholder: "月", width: 36, label: "月份")
            separator
            component(.day, text: $model.dayText, placeholder: "日", width: 36, label: "日期")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 4)
        .onChange(of: model.yearText) { _, _ in changed() }
        .onChange(of: model.monthText) { _, _ in changed() }
        .onChange(of: model.dayText) { _, _ in changed() }
    }

    private var separator: some View {
        Text("-")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func component(
        _ component: WorkspaceSQLDateEditingModel.Component,
        text: Binding<String>,
        placeholder: String,
        width: CGFloat,
        label: String
    ) -> some View {
        HStack(spacing: 0) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: width, height: 30)
                .onSubmit { model.normalize(component) }
                .accessibilityLabel(label)
            Divider().frame(height: 21).opacity(0.25)
            VStack(spacing: -3) {
                Button { model.adjust(component, by: 1); changed() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 17, height: 13)
                }
                Button { model.adjust(component, by: -1); changed() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 17, height: 13)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 2)
        .padding(.trailing, 1)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7))
    }

    private func changed() {
        onValidityChange(model.isValid)
        if let date = model.date { onChange(date) }
    }
}

struct WorkspaceSQLTimeEditorView: View {
    @ObservedObject var model: WorkspaceSQLTimeEditingModel
    let onChange: (Int, Int, Int, String) -> Void
    let onValidityChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 5) {
            component(.hour, text: $model.hourText, range: "00–23", label: "小时")
            separator
            component(.minute, text: $model.minuteText, range: "00–59", label: "分钟")
            separator
            component(.second, text: $model.secondText, range: "00–59", label: "秒")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 4)
        .onChange(of: model.hourText) { _, _ in changed() }
        .onChange(of: model.minuteText) { _, _ in changed() }
        .onChange(of: model.secondText) { _, _ in changed() }
    }

    private var separator: some View {
        Text(":")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func component(
        _ component: WorkspaceSQLTimeEditingModel.Component,
        text: Binding<String>,
        range: String,
        label: String
    ) -> some View {
        HStack(spacing: 0) {
            TextField(range, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 35, height: 30)
                .onSubmit { model.normalize(component) }
                .accessibilityLabel(label)
            Divider()
                .frame(height: 21)
                .opacity(0.25)
            VStack(spacing: -3) {
                Button { model.adjust(component, by: 1); changed() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 17, height: 13)
                }
                Button { model.adjust(component, by: -1); changed() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 17, height: 13)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 2)
        .padding(.trailing, 1)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7))
    }

    private func changed() {
        onValidityChange(model.isValid)
        guard model.isValid,
              let hour = model.hour,
              let minute = model.minute,
              let second = model.second
        else { return }
        onChange(hour, minute, second, model.fractionText)
    }
}

/// A small calendar made for the SQL editor popover. It keeps the SQL wall-clock
/// calendar separate from the user's system time zone and exposes the month/year
/// title as a fast picker for dates that are far away from the current month.
struct WorkspaceSQLCalendarView: View {
    @ObservedObject var model: WorkspaceSQLCalendarModel
    let calendar: Calendar
    let onChange: (Date) -> Void

    @State private var displayedMonth: Date
    @State private var showsMonthYearPicker = false

    init(model: WorkspaceSQLCalendarModel, calendar: Calendar, onChange: @escaping (Date) -> Void) {
        self.model = model
        self.calendar = calendar
        self.onChange = onChange
        _displayedMonth = State(initialValue: Self.startOfMonth(calendar: calendar, date: model.date))
    }

    var body: some View {
        VStack(spacing: 9) {
            header
            weekdayHeader
            dayGrid
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onChange(of: model.date) { _, newDate in
            displayedMonth = Self.startOfMonth(calendar: calendar, date: newDate)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            calendarButton(systemName: "chevron.left", label: "上个月") {
                displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
            }
            .accessibilityIdentifier("sqlDatePreviousMonth")

            Button {
                showsMonthYearPicker.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(monthYearTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择月份和年份")
            .accessibilityIdentifier("sqlDateMonthYearButton")
            .popover(isPresented: $showsMonthYearPicker, arrowEdge: .top) {
                WorkspaceSQLMonthYearPicker(
                    displayedMonth: $displayedMonth,
                    calendar: calendar,
                    close: { showsMonthYearPicker = false }
                )
            }

            calendarButton(systemName: "chevron.right", label: "下个月") {
                displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
            }
            .accessibilityIdentifier("sqlDateNextMonth")
        }
        .frame(height: 28)
    }

    private var weekdayHeader: some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...]) + Array(symbols[..<(calendar.firstWeekday - 1)])
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 20)
    }

    private var dayGrid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(monthDays) { item in
                if let date = item.date {
                    Button {
                        select(date)
                    } label: {
                        Text(calendar.component(.day, from: date), format: .number)
                            .font(.system(size: 14, weight: isSelected(date) ? .semibold : .regular))
                            .foregroundStyle(isSelected(date) ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 27)
                            .background {
                                if isSelected(date) {
                                    Circle().fill(Color.accentColor)
                                } else if isToday(date) {
                                    Circle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dayAccessibilityLabel(date))
                    .accessibilityIdentifier("sqlDateDay-\(calendar.component(.day, from: date))")
                } else {
                    Color.clear.frame(height: 27)
                }
            }
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    private var monthDays: [CalendarDay] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))
        else { return [] }
        let firstWeekday = calendar.component(.weekday, from: firstDay)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dates = (0..<leading).map { _ in CalendarDay(date: nil) }
            + range.compactMap { day -> CalendarDay? in
                var components = calendar.dateComponents([.year, .month], from: displayedMonth)
                components.day = day
                return calendar.date(from: components).map(CalendarDay.init(date:))
            }
        return dates
    }

    private var monthYearTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: displayedMonth)
    }

    private func calendarButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 27, height: 27)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    private func select(_ date: Date) {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let time = calendar.dateComponents([.hour, .minute, .second], from: model.date)
        var components = day
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        guard let selected = calendar.date(from: components) else { return }
        model.date = selected
        onChange(selected)
    }

    private func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: model.date)
    }

    private func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    private func dayAccessibilityLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    private static func startOfMonth(calendar: Calendar, date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private struct CalendarDay: Identifiable {
        let id = UUID()
        let date: Date?
    }
}

private struct WorkspaceSQLMonthYearPicker: View {
    @Binding var displayedMonth: Date
    let calendar: Calendar
    let close: () -> Void

    @State private var monthSelection: Int
    @State private var yearText: String

    init(displayedMonth: Binding<Date>, calendar: Calendar, close: @escaping () -> Void) {
        _displayedMonth = displayedMonth
        self.calendar = calendar
        self.close = close
        let year = calendar.component(.year, from: displayedMonth.wrappedValue)
        _monthSelection = State(initialValue: calendar.component(.month, from: displayedMonth.wrappedValue))
        _yearText = State(initialValue: String(year))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("选择月份和年份")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 8) {
                Picker("月份", selection: $monthSelection) {
                    ForEach(1...12, id: \.self) { month in
                        Text(monthTitle(month)).tag(month)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 112, height: 30)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: monthSelection) { _, month in
                    set(month: month, year: selectedYear)
                }

                TextField("年份", text: $yearText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 82, height: 30)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7))
                    .onChange(of: yearText) { _, newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(4))
                        if digits != newValue { yearText = digits }
                        if let year = Int(digits), (1...9999).contains(year) {
                            set(month: monthSelection, year: year)
                        }
                    }
                    .accessibilityLabel("年份")
            }

            HStack {
                Spacer()
                Button("完成", action: close)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 270)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
        }
    }

    private var selectedYear: Int { calendar.component(.year, from: displayedMonth) }

    private func monthTitle(_ month: Int) -> String {
        let symbols = calendar.shortMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : String(month)
    }

    private func set(month: Int, year: Int) {
        var components = calendar.dateComponents([.year, .month, .day], from: displayedMonth)
        components.year = year
        components.month = month
        let maxDay = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? displayedMonth)?.count ?? 28
        components.day = min(components.day ?? 1, maxDay)
        displayedMonth = calendar.date(from: components) ?? displayedMonth
        monthSelection = month
        yearText = String(year)
    }
}
