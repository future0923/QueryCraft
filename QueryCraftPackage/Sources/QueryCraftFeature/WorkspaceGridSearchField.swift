import AppKit
import SwiftUI

struct WorkspaceGridSearchField: NSViewRepresentable {
    @Environment(\.controlSize) private var controlSize
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let submit: () -> Void
    let cancel: () -> Void
    var accessibilityIdentifier = "gridSearchField"
    var moveUp: () -> Void = {}
    var moveDown: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.controlSize = appKitControlSize
        searchField.placeholderString = placeholder
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = context.coordinator
        searchField.setAccessibilityIdentifier(accessibilityIdentifier)
        return searchField
    }

    func updateNSView(
        _ searchField: NSSearchField,
        context: Context
    ) {
        context.coordinator.parent = self
        searchField.controlSize = appKitControlSize
        searchField.setAccessibilityIdentifier(accessibilityIdentifier)
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        searchField.placeholderString = placeholder

        guard
            context.coordinator.lastFocusRequest != focusRequest,
            focusRequest > 0
        else {
            return
        }
        context.coordinator.lastFocusRequest = focusRequest
        Task { @MainActor [weak searchField] in
            await Task.yield()
            guard let searchField else { return }
            searchField.window?.makeFirstResponder(searchField)
            searchField.selectText(nil)
        }
    }

    private var appKitControlSize: NSControl.ControlSize {
        switch controlSize {
        case .mini:
            .mini
        case .small:
            .small
        case .regular:
            .regular
        case .large, .extraLarge:
            .large
        @unknown default:
            .regular
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: WorkspaceGridSearchField
        var lastFocusRequest = 0

        init(parent: WorkspaceGridSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }
            parent.text = searchField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.cancel()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.moveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.moveDown()
                return true
            default:
                return false
            }
        }
    }
}
