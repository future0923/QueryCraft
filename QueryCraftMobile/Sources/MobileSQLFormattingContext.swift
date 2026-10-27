import Observation
import UIKit

/// Routes toolbar actions to the mounted native editor without changing focus.
@MainActor @Observable final class MobileSQLFormattingContext {
    private(set) var isFormatting = false
    var errorMessage: String?
    @ObservationIgnored private weak var editor: MobileSQLTextView?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func attach(_ editor: MobileSQLTextView) { self.editor = editor }
    func detach(_ editor: MobileSQLTextView) {
        guard self.editor === editor else { return }
        cancel(); self.editor = nil
    }

    @discardableResult func format(_ request: SQLFormattingRequest) -> Task<Void, Never>? {
        cancel(); errorMessage = nil
        guard let editor, let action = editor.formatSQL else {
            errorMessage = SQLFormattingError.editorUnavailable.localizedDescription
            return nil
        }
        // Capture the user's action before yielding to the keyboard/input loop.
        // Composition may end (or text/caret may change) before the Task starts.
        guard editor.markedTextRange == nil else {
            errorMessage = SQLFormattingError.textCompositionActive.localizedDescription
            return nil
        }
        let text = editor.text, selection = editor.selectedRange
        let generation = generation
        isFormatting = true
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard editor.text == text, editor.selectedRange == selection, editor.markedTextRange == nil else {
                    throw SQLFormattingError.sourceChanged
                }
                _ = try await action(request)
            }
            catch is CancellationError { }
            catch {
                if let self, self.generation == generation, !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
            guard let self, self.generation == generation else { return }
            self.isFormatting = false; self.task = nil
        }
        self.task = task
        return task
    }

    func cancel() {
        generation += 1; task?.cancel(); task = nil; isFormatting = false
    }
}
