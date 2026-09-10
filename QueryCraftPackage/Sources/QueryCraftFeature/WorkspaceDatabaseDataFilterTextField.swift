import AppKit
import SwiftUI

struct WorkspaceDatabaseDataFilterTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> WorkspaceDatabaseDataFilterNativeTextField {
        let textField = WorkspaceDatabaseDataFilterNativeTextField()
        textField.controlSize = .regular
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.backgroundColor = .controlColor
        textField.textColor = .controlTextColor
        textField.usesSingleLineMode = true
        textField.delegate = context.coordinator
        textField.setAccessibilityLabel(accessibilityLabel)
        return textField
    }

    func updateNSView(
        _ textField: WorkspaceDatabaseDataFilterNativeTextField,
        context: Context
    ) {
        context.coordinator.text = $text
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
        textField.setAccessibilityLabel(accessibilityLabel)
        textField.requestFocus(focusRequest)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = textField.stringValue
        }
    }
}
