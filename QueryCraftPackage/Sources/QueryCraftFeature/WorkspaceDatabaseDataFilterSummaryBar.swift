import SwiftUI

struct WorkspaceDatabaseDataFilterSummaryBar: View {
    let filter: WorkspaceDatabaseDataFilter
    let edit: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.tint)

            Text(summary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(summary)

            Spacer(minLength: 12)

            Button(
                AppCopy.current.text("编辑筛选", "Edit Filter"),
                action: edit
            )
            .buttonStyle(.link)

            Button(
                AppCopy.current.text("清除筛选", "Clear Filter"),
                systemImage: "xmark.circle",
                action: clear
            )
            .labelStyle(.iconOnly)
            .help(AppCopy.current.text("清除筛选", "Clear Filter"))
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("databaseDataFilterSummaryBar")
    }

    private var summary: String {
        let conditions = filter.effectiveConditions
        let descriptions = conditions.prefix(2).map { condition in
            var text = filter.usesElasticsearchConditions
                ? "\(condition.elasticsearchClause.rawValue) · \(condition.columnName) · \(condition.operation.title)"
                : "\(condition.columnName) \(condition.operation.title)"
            if condition.operation.requiresValue {
                text += " \(condition.value)"
            }
            if condition.operation.requiresSecondValue {
                text += AppCopy.current.text(
                    " 到 \(condition.secondValue)",
                    " and \(condition.secondValue)"
                )
            }
            return text
        }
        let separator = filter.usesElasticsearchConditions
            ? "  |  "
            : filter.logic == .matchAll
                ? AppCopy.current.text(" 且 ", " and ")
                : AppCopy.current.text(" 或 ", " or ")
        var result = descriptions.joined(separator: separator)
        if conditions.count > descriptions.count {
            result += AppCopy.current.text(
                "，另有 \(conditions.count - descriptions.count) 条",
                ", plus \(conditions.count - descriptions.count) more"
            )
        }
        return result
    }
}
