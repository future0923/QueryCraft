import SwiftUI

struct DataExportBatchSizeField: View {
    @Binding var value: Int

    var body: some View {
        LabeledContent {
            Stepper(value: $value, in: WorkspaceDataExportPreferences.batchSizeRange, step: 1) {
                Text(value, format: .number.grouping(.never))
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
            }
                .controlSize(.small)
                .accessibilityLabel(AppCopy.current.text("每条 INSERT 最多行数", "Maximum Rows per INSERT"))
                .accessibilityIdentifier("settings.data.export.sqlInsertBatchSize")
        } label: {
            SettingsControlLabel(
                title: AppCopy.current.text("每条 INSERT 最多行数", "Maximum Rows per INSERT"),
                description: AppCopy.current.text("默认 1000；使用右侧步进控件调整。", "Default: 1000; adjust with the stepper on the right.")
            )
        }
    }
}
