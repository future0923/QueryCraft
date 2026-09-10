import AppKit
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
final class WorkspaceQueryEditorCommandCoordinator: @preconcurrency TextViewCoordinator,
    TextViewKeyCommandHandling
{
    private weak var document: WorkspaceQueryDocumentModel?
    private weak var languageService: WorkspaceSQLLanguageService?
    private weak var controller: TextViewController?
    private weak var textView: TextView?
    private var executionPlanHandler: (@MainActor (SQLExecutionBatchPlan) -> Void)?
    private var saveHandler: (@MainActor () -> Void)?
    private var needsInitialFocus = true

    init(
        document: WorkspaceQueryDocumentModel,
        languageService: WorkspaceSQLLanguageService,
        save: (@MainActor () -> Void)? = nil
    ) {
        self.document = document
        self.languageService = languageService
        saveHandler = save
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        textView = controller.textView
        configureScrolling(in: controller)
    }

    func controllerDidAppear(controller: TextViewController) {
        self.controller = controller
        textView = controller.textView
        configureScrolling(in: controller)
        focusEditorIfNeeded()
    }

    func destroy() {
        // The context outlives transient SourceEditor controllers. Weak UI
        // references clear themselves when the final controller is released.
    }

    func setExecutionPlanHandler(
        _ handler: (@MainActor (SQLExecutionBatchPlan) -> Void)?
    ) {
        executionPlanHandler = handler
    }

    func activateEditor() {
        needsInitialFocus = true
        Task { @MainActor [weak self] in
            self?.focusEditorIfNeeded()
        }
    }

    func handleTextViewKeyCommand(
        _ command: TextViewKeyCommand,
        textView: TextView
    ) -> Bool {
        guard let document else { return false }

        switch command {
        case .commandReturn:
            guard !textView.hasMarkedText() else { return true }
            guard !document.executionState.isRunning else { return true }
            run(.selectionOrCurrentStatement, document: document)
            return true

        case .commandShiftReturn:
            guard !textView.hasMarkedText() else { return true }
            guard !document.executionState.isRunning else { return true }
            run(.all, document: document)
            return true

        case .commandI:
            guard !textView.hasMarkedText() else { return true }
            startFormatting(.selectionOrCurrentStatement, textView: textView)
            return true

        case .commandS:
            guard !textView.hasMarkedText() else { return true }
            save()
            return true

        case .commitTransaction:
            return executeTransactionCommand(.commit, document: document)

        case .rollbackTransaction:
            return executeTransactionCommand(.rollback, document: document)

        case .escape:
            guard !textView.hasMarkedText() else { return false }
            guard document.executionState.isRunning else { return false }
            Task {
                await document.stop()
            }
            return true
        }
    }

    func format(_ request: SQLFormattingRequest) {
        guard let textView, !textView.hasMarkedText() else { return }
        startFormatting(request, textView: textView)
    }

    func save() {
        guard document?.canSave == true else { return }
        saveHandler?()
    }

    func synchronizeDocumentText() {
        guard let document, let textView else { return }
        document.sql = textView.string
    }

    func replaceEditorTextIfNeeded(_ text: String) {
        guard let textView, textView.string != text else { return }

        let previousSelection = textView.selectedRange()
        let textLength = (text as NSString).length
        let selectionLocation = min(previousSelection.location, textLength)
        let selectionLength = min(
            previousSelection.length,
            textLength - selectionLocation
        )

        guard let controller, controller.textView === textView else { return }
        controller.setText(text)
        // CodeEdit rebuilds its highlighter in setText(), but the new
        // highlighter waits for a visible-range change before doing any work.
        // Reassigning the language uses its public full-document invalidation.
        controller.language = .sql
        textView.selectionManager.setSelectedRange(
            NSRange(location: selectionLocation, length: selectionLength)
        )
        textView.scrollSelectionToVisible()
    }

    @discardableResult
    func applyFormatting(
        _ request: SQLFormattingRequest,
        textView: TextView
    ) async throws -> Bool {
        guard let languageService else {
            throw SQLFormattingError.editorUnavailable
        }
        guard let edit = try await languageService.formattingEdit(for: request)
        else {
            return false
        }

        textView.undoManager?.beginUndoGrouping()
        textView.replaceCharacters(
            in: edit.range.nsRange,
            with: edit.replacement
        )
        textView.undoManager?.endUndoGrouping()
        textView.selectionManager.setSelectedRange(edit.selectedRange)
        textView.scrollSelectionToVisible()
        return true
    }

    private func run(
        _ request: SQLExecutionTargetRequest,
        document: WorkspaceQueryDocumentModel
    ) {
        guard let languageService else { return }
        Task {
            do {
                let plan = try await languageService.executionPlan(
                    for: request
                )
                if let executionPlanHandler {
                    executionPlanHandler(plan)
                } else {
                    await document.execute(plan)
                }
            } catch {
                document.reportExecutionTargetFailure(error)
            }
        }
    }

    private func startFormatting(
        _ request: SQLFormattingRequest,
        textView: TextView
    ) {
        Task { @MainActor [weak self, weak textView] in
            guard let self, let textView else { return }
            do {
                _ = try await applyFormatting(request, textView: textView)
            } catch {
                presentFormattingFailure(error, for: textView)
            }
        }
    }

    private func focusEditorIfNeeded() {
        guard needsInitialFocus,
              let textView,
              let window = textView.window,
              window.makeFirstResponder(textView)
        else {
            return
        }
        needsInitialFocus = false
    }

    private func configureScrolling(in controller: TextViewController) {
        guard let scrollView = controller.scrollView else { return }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !controller.wrapLines
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }

    private func executeTransactionCommand(
        _ command: WorkspaceQueryTransactionCommand,
        document: WorkspaceQueryDocumentModel
    ) -> Bool {
        guard document.transactionState == .inTransaction,
              !document.executionState.isRunning
        else {
            return false
        }
        Task {
            await document.executeTransactionCommand(command)
        }
        return true
    }

    private func presentFormattingFailure(
        _ error: Error,
        for textView: TextView
    ) {
        guard let window = textView.window, window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text(
            "无法格式化 SQL",
            "Cannot Format SQL"
        )
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window)
    }
}
