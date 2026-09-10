//
//  SuggestionController.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 6/18/24.
//

import AppKit
import CodeEditTextView

public final class SuggestionController: NSWindowController {
    static var shared: SuggestionController = SuggestionController()

    // MARK: - Properties

    /// Whether the suggestion window is visible
    var isVisible: Bool {
        window?.isVisible ?? false || popover?.isShown ?? false
    }

    var model: SuggestionViewModel = SuggestionViewModel()

    // MARK: - Private Properties

    /// Maximum number of visible rows (8.5)
    static let MAX_VISIBLE_ROWS: CGFloat = 8.5
    /// Padding at top and bottom of the window
    static let WINDOW_PADDING: CGFloat = 5

    /// Tracks when the window is placed above the cursor
    var isWindowAboveCursor = false
    var completionSessionLayout: CompletionSessionLayout?

    var popover: NSPopover?

    /// Holds the observer for the window resign notifications
    private var windowResignObserver: NSObjectProtocol?

    // MARK: - Initialization

    public init() {
        let window = Self.makeWindow()

        let controller = SuggestionViewController()
        controller.model = model
        window.contentViewController = controller

        super.init(window: window)

        controller.windowController = self

        if window.isVisible {
            window.close()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Show Completions

    func showCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        asPopover: Bool = false
    ) {
        model.showCompletions(
            textView: textView,
            delegate: delegate,
            cursorPosition: cursorPosition
        ) { parentWindow, cursorRect in
            if asPopover {
                self.clearCompletionAnchor()
                self.popover?.close()
                self.popover = nil

                let windowPosition = parentWindow.convertFromScreen(cursorRect)
                let textViewPosition = textView.textView.convert(windowPosition, from: nil)
                let popover = NSPopover()
                popover.behavior = .transient

                let controller = SuggestionViewController()
                controller.model = self.model
                controller.windowController = self
                controller.styleView(using: textView)
                controller.renderInitialCandidates(using: textView)

                popover.contentViewController = controller
                popover.show(relativeTo: textViewPosition, of: textView.textView, preferredEdge: .maxY)
                self.popover = popover
            } else {
                self.clearCompletionAnchor()
                self.setCompletionAnchor(cursorRect: cursorRect, font: textView.font)
                if let controller = self.contentViewController as? SuggestionViewController {
                    controller.styleView(using: textView)
                    controller.renderInitialCandidates(using: textView)
                }
                self.showWindow(attachedTo: parentWindow)
                self.repositionWindowAtCompletionAnchor()
            }
        }
    }

    func refreshVisibleCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition
    ) {
        guard isVisible,
              model.activeTextView === textView,
              model.delegate === delegate
        else {
            return
        }
        model.refreshCompletions(
            textView: textView,
            delegate: delegate,
            cursorPosition: cursorPosition,
            itemsUnavailable: { [weak self] in
                self?.close()
            },
            itemsLoaded: { [weak self] _, _ in
                guard let self else { return }
                if let controller = self.contentViewController as? SuggestionViewController {
                    controller.renderVisibleCandidateRefresh()
                }
            }
        )
    }

    /// Opens the window as a child of another window.
    public func showWindow(attachedTo parentWindow: NSWindow) {
        guard let window = window else { return }
        parentWindow.addChildWindow(window, ordered: .above)

        // Close on window switch observer
        // Initialized outside of `setupEventMonitors` in order to grab the parent window
        if let existingObserver = windowResignObserver {
            NotificationCenter.default.removeObserver(existingObserver)
        }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }

        window.orderFront(nil)
        window.contentViewController?.viewWillAppear()
    }

    /// Close the window
    public override func close() {
        model.willClose()
        clearCompletionAnchor()
        removeWindowResignObserver()

        contentViewController?.viewWillDisappear()
        if let popover {
            popover.contentViewController?.viewWillDisappear()
            popover.close()
            self.popover = nil
        }

        super.close()
    }

    private func removeWindowResignObserver() {
        guard let windowResignObserver else { return }
        NotificationCenter.default.removeObserver(windowResignObserver)
        self.windowResignObserver = nil
    }

    // MARK: - Cursors Updated

    func cursorsUpdated(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        position: CursorPosition,
        presentIfNot: Bool = false,
        asPopover: Bool = false
    ) {
        if !asPopover && popover != nil {
            close()
        }

        if presentIfNot,
           isVisible,
           model.activeTextView === textView,
           model.delegate === delegate,
           !asPopover
        {
            refreshVisibleCompletions(
                textView: textView,
                delegate: delegate,
                cursorPosition: position
            )
            return
        }

        let didCommitItems = model.cursorsUpdated(
            textView: textView,
            delegate: delegate,
            position: position
        ) {
            close()

            if presentIfNot {
                self.showCompletions(
                    textView: textView,
                    delegate: delegate,
                    cursorPosition: position,
                    asPopover: asPopover
                )
            }
        }
        if didCommitItems,
           let controller = contentViewController as? SuggestionViewController
        {
            controller.renderVisibleCandidateRefresh()
        }
    }
}

public extension TextViewController {
    func refreshVisibleCompletions() {
        guard let completionDelegate else { return }
        SuggestionController.shared.refreshVisibleCompletions(
            textView: self,
            delegate: completionDelegate,
            cursorPosition: CursorPosition(range: textView.selectedRange())
        )
    }
}
