import Foundation
import Observation
import UIKit

/// The model retains selection across navigation; an attached editor supplies
/// the actual UIKit selection and IME state when a toolbar action is pressed.
@MainActor @Observable final class MobileSQLExecutionInput {
    var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored private weak var editor: UITextView?

    func attach(_ editor: UITextView) { self.editor = editor }
    func detach(_ editor: UITextView) { if self.editor === editor { self.editor = nil } }

    func capture(text: String) throws -> NSRange {
        guard let editor else { return selection }
        guard editor.markedTextRange == nil else { throw SQLExecutionTargetError.textCompositionActive }
        guard editor.text == text else { throw SQLExecutionTargetError.sourceChanged }
        selection = editor.selectedRange
        return selection
    }

    func matches(text: String, selection: NSRange) -> Bool {
        guard let editor else { return self.selection == selection }
        return editor.text == text && editor.selectedRange == selection && editor.markedTextRange == nil
    }
}
