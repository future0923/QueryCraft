import SwiftUI

struct RedisEditableStringValueView: View {
    @Bindable var editor: RedisKeyEditorState
    let isEnabled: Bool

    @State private var allowsJSON = false
    @State private var formatter = RedisValueFormatter()

    var body: some View {
        VStack(spacing: 0) {
            RedisScalarValueToolbar(
                selectedFormat: $editor.stringEditingFormat,
                allowsJSON: allowsJSON,
                allowsText: true,
                expirationEditor: editor,
                isEnabled: isEnabled
            )
            Divider()
            if editor.stringTotalByteCount > 100 * 1_024 * 1_024 {
                Text(
                    AppCopy.current.text(
                        "该 String 超过 100 MB，只显示前 64 KB，不能在内存编辑器中修改。",
                        "This string exceeds 100 MB. Only the first 64 KB is shown and in-memory editing is disabled."
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
            }
            Group {
                if editor.stringEditingFormat == .json {
                    WorkspaceJSONTextView(
                        text: $editor.stringDisplayValue,
                        isEditable: isEnabled && editor.supportsStringPresentationEditing,
                        accessibilityLabel: AppCopy.current.text("Redis String 值", "Redis string value")
                    )
                } else {
                    RedisEditableStringTextView(
                        text: $editor.stringDisplayValue,
                        isEditable: isEnabled
                            && editor.supportsStringPresentationEditing,
                        accessibilityLabel: AppCopy.current.text(
                            "Redis String 值",
                            "Redis string value"
                        )
                    )
                }
            }
            .padding(8)
        }
        .task(id: editor.stringData) {
            await updateJSONAvailability()
        }
        .task(id: editor.stringEditingFormat) {
            await applySelectedFormat()
        }
        .onAppear {
            editor.synchronizeStringPresentation()
        }
    }

    private func updateJSONAvailability() async {
        guard let value = editor.stringData.losslessUTF8String else {
            allowsJSON = false
            if editor.stringEditingFormat == .json {
                editor.stringEditingFormat = .text
            } else {
                await applySelectedFormat()
            }
            return
        }
        let formatted = await formatter.formattedJSON(from: value)
        guard !Task.isCancelled else { return }
        allowsJSON = formatted != nil
        if formatted == nil, editor.stringEditingFormat == .json {
            editor.stringEditingFormat = .text
        } else {
            await applySelectedFormat()
        }
    }

    private func applySelectedFormat() async {
        let selectedFormat = editor.stringEditingFormat
        let sourceData = editor.stringData
        switch selectedFormat {
        case .text:
            editor.applyStringPresentation(editor.stringTextPresentation)
        case .json:
            guard let value = sourceData.losslessUTF8String else {
                editor.stringEditingFormat = .hex
                return
            }
            guard let formatted = await formatter.formattedJSON(from: value),
                  !Task.isCancelled,
                  editor.stringEditingFormat == selectedFormat,
                  editor.stringData == sourceData
            else {
                if editor.stringEditingFormat == .json,
                   editor.stringData == sourceData
                {
                    editor.stringEditingFormat = .text
                }
                return
            }
            editor.applyStringPresentation(formatted)
        case .hex:
            editor.applyStringPresentation(
                RedisHexCodec.format(sourceData.data)
            )
        }
    }
}
