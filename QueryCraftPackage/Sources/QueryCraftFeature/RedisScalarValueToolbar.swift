import SwiftUI

struct RedisScalarValueToolbar: View {
    @Binding var selectedFormat: RedisValueDisplayFormat
    let allowsJSON: Bool
    var allowsText = true
    var allowsHex = true
    var expirationEditor: RedisKeyEditorState?
    var isEnabled = true

    var body: some View {
        HStack(spacing: 10) {
            RedisValueDisplayFormatPicker(
                selectedFormat: $selectedFormat,
                allowsText: allowsText,
                allowsJSON: allowsJSON,
                allowsHex: allowsHex
            )
            .frame(width: formatPickerWidth)
            .help(AppCopy.current.text("切换显示格式", "Change display format"))

            Spacer(minLength: 0)

            if let expirationEditor {
                RedisKeyExpirationControls(
                    editor: expirationEditor,
                    isEnabled: isEnabled
                )
            }

        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
    }

    private var formatPickerWidth: CGFloat {
        let count = (allowsText ? 1 : 0)
            + (allowsJSON ? 1 : 0)
            + (allowsHex ? 1 : 0)
        return CGFloat(count) * 72
    }
}
