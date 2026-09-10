import AppKit
import SwiftUI

struct WorkspaceRedisCommandInputField: NSViewRepresentable {
    let text: String
    let isEditable: Bool
    let focusRequest: Int
    let textChanged: (String) -> Void
    let submit: () -> Void
    let moveUp: () -> Bool
    let moveDown: () -> Bool
    let acceptCandidate: () -> Bool
    let selectPreviousCandidate: () -> Bool
    let cancel: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WorkspaceRedisCommandNativeTextField {
        let textField = WorkspaceRedisCommandNativeTextField()
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        textField.placeholderString = AppCopy.current.text(
            "输入 Redis 命令",
            "Enter a Redis command"
        )
        textField.delegate = context.coordinator
        textField.setAccessibilityLabel(
            AppCopy.current.text("Redis 命令输入", "Redis command input")
        )
        textField.setAccessibilityIdentifier("redisCommandInput")
        return textField
    }

    func updateNSView(
        _ textField: WorkspaceRedisCommandNativeTextField,
        context: Context
    ) {
        context.coordinator.parent = self
        Self.synchronize(text, in: textField)
        textField.isEditable = isEditable
        textField.isSelectable = isEditable
        textField.placeholderString = AppCopy.current.text(
            "输入 Redis 命令",
            "Enter a Redis command"
        )
        textField.requestFocus(focusRequest)
    }

    static func synchronize(_ text: String, in textField: NSTextField) {
        let editor = textField.currentEditor()
        guard textField.stringValue != text || editor?.string != text else {
            return
        }
        textField.stringValue = text
        editor?.string = text
        editor?.selectedRange = NSRange(
            location: text.utf16.count,
            length: 0
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WorkspaceRedisCommandInputField

        init(parent: WorkspaceRedisCommandInputField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object
                as? WorkspaceRedisCommandNativeTextField
            else { return }
            textField.configureCurrentEditor()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }
            parent.textChanged(
                textField.currentEditor()?.string ?? textField.stringValue
            )
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.acceptCandidate() {
                    return true
                }
                parent.submit()
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.moveUp()
            case #selector(NSResponder.moveDown(_:)):
                return parent.moveDown()
            case #selector(NSResponder.insertTab(_:)):
                return parent.acceptCandidate()
            case #selector(NSResponder.insertBacktab(_:)):
                return parent.selectPreviousCandidate()
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.cancel()
            default:
                return false
            }
        }
    }
}
