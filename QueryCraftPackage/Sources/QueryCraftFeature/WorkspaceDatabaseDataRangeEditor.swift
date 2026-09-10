import SwiftUI

struct WorkspaceDatabaseDataRangeEditor: View {
    @Binding var limit: Int
    @Binding var offset: Int

    let apply: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppCopy.current.text("数量", "Limit"))
                        .foregroundStyle(.secondary)

                    TextField(
                        AppCopy.current.text("数量", "Limit"),
                        value: $limit,
                        format: .number
                    )
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .accessibilityIdentifier("databaseDataLimitField")
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(AppCopy.current.text("偏移量", "Offset"))
                        .foregroundStyle(.secondary)

                    TextField(
                        AppCopy.current.text("偏移量", "Offset"),
                        value: $offset,
                        format: .number
                    )
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .accessibilityIdentifier("databaseDataOffsetField")
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: apply) {
                Text(AppCopy.current.text("应用范围", "Apply Range"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
            .accessibilityIdentifier("databaseDataRangeApplyButton")
        }
        .controlSize(.regular)
        .foregroundStyle(.primary)
        .padding(14)
        .frame(width: 260)
    }

    private var canApply: Bool {
        validationMessage == nil
    }

    private var validationMessage: String? {
        if offset < 0 {
            return AppCopy.current.text(
                "偏移量必须大于或等于 0。",
                "Offset must be 0 or greater."
            )
        }
        if limit < 1 {
            return AppCopy.current.text(
                "数量必须大于或等于 1。",
                "Limit must be 1 or greater."
            )
        }
        return nil
    }
}
