import SwiftUI

struct RedisKeyExpirationControls: View {
    @Bindable var editor: RedisKeyEditorState
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("TTL")
                .foregroundStyle(.secondary)

            Picker("TTL", selection: $editor.expirationMode) {
                ForEach(RedisKeyExpirationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(!isEnabled)

            if editor.expirationMode == .expires {
                TextField(
                    AppCopy.current.text("毫秒", "Milliseconds"),
                    text: $editor.ttlMillisecondsText
                )
                .frame(width: 104)
                .multilineTextAlignment(.trailing)
                .disabled(!isEnabled)

                Text("ms")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
