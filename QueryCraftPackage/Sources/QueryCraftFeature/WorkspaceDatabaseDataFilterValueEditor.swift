import SwiftUI

struct WorkspaceDatabaseDataFilterValueEditor: View {
    @Binding var condition: WorkspaceDatabaseDataFilterCondition
    let menuValues: [String]
    let focusedField: FocusState<WorkspaceDatabaseDataFilterFocus?>.Binding
    let valueFocusRequest: Int

    var body: some View {
        if condition.operation == .exists {
            Text(AppCopy.current.text("不需要值", "No Value Required"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.separator, style: StrokeStyle(dash: [3, 2]))
                }
                .accessibilityLabel(
                    AppCopy.current.text("不需要值", "No Value Required")
                )
        } else if !condition.operation.requiresValue {
            Spacer(minLength: 150)
        } else if !menuValues.isEmpty {
            Picker(
                AppCopy.current.text("值", "Value"),
                selection: $condition.value
            ) {
                ForEach(menuValues, id: \.self) { value in
                    Text(valueTitle(value)).tag(value)
                }
            }
            .labelsHidden()
            .focused(focusedField, equals: .value(condition.id))
            .frame(maxWidth: .infinity)
        } else if condition.operation.requiresSecondValue {
            HStack(spacing: 6) {
                WorkspaceDatabaseDataFilterTextField(
                    text: $condition.value,
                    placeholder: AppCopy.current.text("起始值", "From"),
                    accessibilityLabel: AppCopy.current.text("起始值", "From"),
                    focusRequest: valueFocusRequest
                )
                .focused(focusedField, equals: .value(condition.id))
                WorkspaceDatabaseDataFilterTextField(
                    text: $condition.secondValue,
                    placeholder: AppCopy.current.text("结束值", "To"),
                    accessibilityLabel: AppCopy.current.text("结束值", "To"),
                    focusRequest: 0
                )
                .focused(focusedField, equals: .secondValue(condition.id))
            }
            .frame(maxWidth: .infinity)
        } else {
            WorkspaceDatabaseDataFilterTextField(
                text: $condition.value,
                placeholder: valuePlaceholder,
                accessibilityLabel: AppCopy.current.text("值", "Value"),
                focusRequest: valueFocusRequest
            )
            .focused(focusedField, equals: .value(condition.id))
            .frame(maxWidth: .infinity)
        }
    }

    private var valuePlaceholder: String {
        condition.operation == .terms
            ? AppCopy.current.text("JSON 数组或逗号分隔", "JSON Array or Comma-Separated")
            : AppCopy.current.text("值", "Value")
    }

    private func valueTitle(_ value: String) -> String {
        guard condition.columnKind == .boolean else { return value }
        return switch value {
        case "0": AppCopy.current.text("否 (0)", "False (0)")
        case "1": AppCopy.current.text("是 (1)", "True (1)")
        default: value
        }
    }
}
