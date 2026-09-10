//
//  SuggestionTriggerCharacterModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 8/25/25.
//

import AppKit
import CodeEditTextView
import TextStory

/// Triggers the suggestion window when trigger characters are typed.
/// Designed to be called in the ``TextViewDelegate``'s didReplaceCharacters method.
///
/// Was originally a `TextFilter` model, however those are called before text is changed and cursors are updated.
/// The suggestion model expects up-to-date cursor positions as well as complete text contents. This being
/// essentially a textview delegate ensures both of those promises are upheld.
@MainActor
final class SuggestionTriggerCharacterModel {
    weak var controller: TextViewController?
    private var lastPosition: NSRange?

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        guard let controller, let completionDelegate = controller.completionDelegate else {
            return
        }

        let triggerCharacters = completionDelegate.completionTriggerCharacters()

        let mutation = TextMutation(
            string: string,
            range: range,
            limit: textView.textStorage.length
        )
        let cursorLocation = mutation.postApplyRange.max
        let triggerCharacter = Self.triggerCharacter(
            afterReplacing: range,
            with: string,
            in: textView.string
        )
        guard let triggerCharacter else {
            lastPosition = nil
            return
        }

        guard triggerCharacters.contains(String(triggerCharacter))
                || triggerCharacter.isNumber
                || triggerCharacter.isLetter else {
            lastPosition = nil
            return
        }

        let range = NSRange(location: cursorLocation, length: 0)
        lastPosition = range
        SuggestionController.shared.cursorsUpdated(
            textView: controller,
            delegate: completionDelegate,
            position: CursorPosition(range: range),
            presentIfNot: true
        )
    }

    static func triggerCharacter(
        afterReplacing range: NSRange,
        with replacement: String,
        in updatedText: String
    ) -> Character? {
        let replacementLength = (replacement as NSString).length
        guard replacementLength < range.length else {
            return replacement.last
        }
        return characterBeforeCursor(
            at: range.location + replacementLength,
            in: updatedText
        )
    }

    private static func characterBeforeCursor(
        at cursorLocation: Int,
        in text: String
    ) -> Character? {
        let source = text as NSString
        guard cursorLocation > 0, cursorLocation <= source.length else {
            return nil
        }
        let range = source.rangeOfComposedCharacterSequence(
            at: cursorLocation - 1
        )
        return source.substring(with: range).last
    }

    func selectionUpdated(_ position: CursorPosition) {
        guard let controller, let completionDelegate = controller.completionDelegate else {
            return
        }

        if lastPosition != position.range {
            SuggestionController.shared.cursorsUpdated(
                textView: controller,
                delegate: completionDelegate,
                position: position
            )
        }
    }
}
