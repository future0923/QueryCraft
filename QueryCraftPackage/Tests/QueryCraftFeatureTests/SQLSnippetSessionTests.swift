import AppKit
import CodeEditTextView
import Testing

@testable import QueryCraftFeature

@MainActor
struct SQLSnippetSessionTests {
    @Test
    func startSelectsTheFirstPlaceholder() {
        let textView = TextView(string: "SELECT * FROM table")
        let session = SQLSnippetSession()
        let placeholder = SQLSourceRange(location: 14, length: 5)

        session.start(textView: textView, placeholderRanges: [placeholder])

        #expect(session.isActive)
        #expect(session.placeholderRanges == [placeholder])
        #expect(session.currentIndex == 0)
        #expect(textView.selectedRange() == placeholder.nsRange)
    }

    @Test
    func startWithoutPlaceholdersStaysInactive() {
        let textView = TextView(string: "SELECT 1;")
        let session = SQLSnippetSession()

        session.start(textView: textView, placeholderRanges: [])

        #expect(!session.isActive)
        #expect(!session.jumpToNextPlaceholder())
    }

    @Test
    func endClearsPlaceholderTracking() {
        let textView = TextView(string: "SELECT * FROM table")
        let session = SQLSnippetSession()
        session.start(
            textView: textView,
            placeholderRanges: [SQLSourceRange(location: 14, length: 5)]
        )

        session.end()

        #expect(!session.isActive)
        #expect(session.placeholderRanges.isEmpty)
        #expect(!session.jumpToPreviousPlaceholder())
    }

    @Test
    func endIfTextViewChangedOnlyEndsForADifferentView() {
        let session = SQLSnippetSession()
        let textView = TextView(string: "SELECT * FROM table")
        let otherTextView = TextView(string: "SELECT * FROM table")
        session.start(
            textView: textView,
            placeholderRanges: [SQLSourceRange(location: 14, length: 5)]
        )

        session.endIfTextViewChanged(textView)
        #expect(session.isActive)

        session.endIfTextViewChanged(otherTextView)
        #expect(!session.isActive)
    }

    @Test
    func tabExitsAfterTheLastStopAndBacktabWrapsToTheLastStop() {
        let mounted = startSession(
            text: "0123456789 END",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
                SQLSourceRange(location: 9, length: 1),
            ]
        )
        #expect(mounted.session.jumpToPreviousPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 9, length: 1))
        #expect(mounted.session.jumpToPreviousPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 3, length: 1))
        #expect(mounted.session.jumpToPreviousPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 0, length: 1))
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 3, length: 1))
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 9, length: 1))
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 10, length: 0))
        #expect(mounted.session.isActive == false)
        #expect(mounted.session.jumpToNextPlaceholder() == false)
    }

    @Test
    func typingAtTheEndOfAPlaceholderExtendsIt() {
        let mounted = startSession(
            text: "SELECT * FROM table",
            ranges: [SQLSourceRange(location: 14, length: 5)]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 19, length: 0),
            replacementLength: 1
        )

        #expect(mounted.session.placeholderRanges == [
            SQLSourceRange(location: 14, length: 6),
        ])
        #expect(mounted.session.currentIndex == 0)
    }

    @Test
    func editsBeforePlaceholdersShiftThem() {
        let mounted = startSession(
            text: "SELECT * FROM table LIMIT 100;",
            ranges: [
                SQLSourceRange(location: 14, length: 5),
                SQLSourceRange(location: 26, length: 3),
            ]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 0, length: 0),
            replacementLength: 3
        )

        #expect(mounted.session.placeholderRanges == [
            SQLSourceRange(location: 17, length: 5),
            SQLSourceRange(location: 29, length: 3),
        ])
    }

    @Test
    func deletionsBeforePlaceholdersShiftThemBack() {
        let mounted = startSession(
            text: "XXSELECT * FROM table",
            ranges: [SQLSourceRange(location: 16, length: 5)]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 0, length: 2),
            replacementLength: 0
        )

        #expect(mounted.session.placeholderRanges == [
            SQLSourceRange(location: 14, length: 5),
        ])
    }

    @Test
    func editsAfterPlaceholdersLeaveThemUnchanged() {
        let mounted = startSession(
            text: "SELECT * FROM table LIMIT 100;",
            ranges: [SQLSourceRange(location: 14, length: 5)]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 25, length: 0),
            replacementLength: 2
        )

        #expect(mounted.session.placeholderRanges == [
            SQLSourceRange(location: 14, length: 5),
        ])
    }

    @Test
    func replacingAPlaceholderTracksTheReplacement() {
        let mounted = startSession(
            text: "SELECT * FROM table",
            ranges: [SQLSourceRange(location: 14, length: 5)]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 14, length: 5),
            replacementLength: 6
        )

        #expect(mounted.session.placeholderRanges == [
            SQLSourceRange(location: 14, length: 6),
        ])
        #expect(mounted.session.currentIndex == 0)
    }

    @Test
    func anEditCrossingSeveralStopsEndsTheSession() {
        let mounted = startSession(
            text: "${a}${b}",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 2, length: 1),
            ]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 0, length: 3),
            replacementLength: 4
        )

        #expect(mounted.session.isActive == false)
        #expect(mounted.session.placeholderRanges.isEmpty)
    }

    @Test
    func clearingTheOnlyPlaceholderKeepsAnEmptyEditableStop() {
        let mounted = startSession(
            text: "SELECT * FROM table",
            ranges: [SQLSourceRange(location: 14, length: 5)]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 14, length: 5),
            replacementLength: 0
        )

        #expect(mounted.session.isActive)
        #expect(mounted.session.placeholderRanges == [SQLSourceRange(location: 14, length: 0)])
    }

    @Test
    func partialReplacementPreservesThePlaceholder() {
        let mounted = startSession(
            text: "0123456789",
            ranges: [
                SQLSourceRange(location: 0, length: 5),
                SQLSourceRange(location: 6, length: 3),
            ]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 2, length: 2),
            replacementLength: 2
        )

        #expect(mounted.session.placeholderRanges == [
            SQLSourceRange(location: 0, length: 5),
            SQLSourceRange(location: 6, length: 3),
        ])
    }

    @Test
    func selectionOutsidePlaceholdersKeepsTheSessionAndHighlights() {
        let mounted = startSession(
            text: "SELECT * FROM table",
            ranges: [SQLSourceRange(location: 14, length: 5)]
        )

        simulateSelection(NSRange(location: 4, length: 0), in: mounted)

        #expect(mounted.session.isActive)
        #expect(mounted.session.currentIndex == 0)
        #expect(
            mounted.session.highlightedRanges == [
                SQLSourceRange(location: 14, length: 5)
            ]
        )
    }

    @Test
    func lineEndNavigationKeepsEveryUnfilledPlaceholderHighlighted() {
        let mounted = startSession(
            text: "0123456789 END",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
                SQLSourceRange(location: 9, length: 1),
            ]
        )

        // ⌘→ 行内导航把光标送到行尾「END」之后，不再结束会话或清空高亮。
        simulateSelection(NSRange(location: 13, length: 0), in: mounted)

        #expect(mounted.session.isActive)
        #expect(mounted.session.currentIndex == 0)
        #expect(
            mounted.session.highlightedRanges == [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
                SQLSourceRange(location: 9, length: 1),
            ]
        )
        #expect(
            mounted.textView.emphasisManager?
                .getEmphases(for: SQLSnippetSession.emphasisGroup).count == 3
        )

        // 从被导航离开的位置，Tab 仍能跳回占位符。
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 3, length: 1))
    }

    @Test
    func quoteWrappingASelectedPlaceholderKeepsOtherHighlights() {
        let mounted = startSession(
            text: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            ranges: [
                SQLSourceRange(location: 0, length: 3),
                SQLSourceRange(location: 8, length: 4),
                SQLSourceRange(location: 20, length: 5),
            ]
        )

        // OpenPairReplacementFilter 包裹选中的占位符时先在末尾插入闭合引号，
        // 再在起点插入引号；两次 applyMutation 都会同步到会话。
        mounted.session.textDidChange(
            in: NSRange(location: 3, length: 0),
            replacementLength: 1
        )
        mounted.session.textDidChange(
            in: NSRange(location: 0, length: 0),
            replacementLength: 1
        )

        #expect(mounted.session.isActive)
        #expect(
            mounted.session.placeholderRanges == [
                SQLSourceRange(location: 0, length: 5),
                SQLSourceRange(location: 10, length: 4),
                SQLSourceRange(location: 22, length: 5),
            ]
        )
        #expect(
            mounted.session.highlightedRanges == [
                SQLSourceRange(location: 10, length: 4),
                SQLSourceRange(location: 22, length: 5),
            ]
        )
        #expect(
            mounted.textView.emphasisManager?
                .getEmphases(for: SQLSnippetSession.emphasisGroup).count == 2
        )

        // 点击进入第三项后，它改用当前项描边，其他待填写项保留淡底色。
        simulateSelection(NSRange(location: 23, length: 0), in: mounted)
        #expect(mounted.session.isActive)
        #expect(mounted.session.highlightedRanges == [SQLSourceRange(location: 10, length: 4)])
        #expect(mounted.textView.emphasisManager?
            .getEmphases(for: SQLSnippetSession.currentEmphasisGroup).map(\.range)
            == [NSRange(location: 22, length: 5)])
    }

    @Test
    func caretOnThePlaceholderBoundaryKeepsTheSession() {
        let mounted = startSession(
            text: "SELECT * FROM table",
            ranges: [SQLSourceRange(location: 14, length: 5)]
        )

        mounted.session.selectionDidChange(to: NSRange(location: 19, length: 0))

        #expect(mounted.session.isActive)
    }

    @Test
    func selectingThePlaceholderKeepsTheSession() {
        let mounted = startSession(
            text: "SELECT * FROM table",
            ranges: [SQLSourceRange(location: 14, length: 5)]
        )

        simulateSelection(NSRange(location: 14, length: 5), in: mounted)
        #expect(mounted.session.isActive)

        // 与占位符不完全相同的选区同样不再结束会话，占位符继续高亮。
        simulateSelection(NSRange(location: 13, length: 7), in: mounted)
        #expect(mounted.session.isActive)
        #expect(
            mounted.session.highlightedRanges == [
                SQLSourceRange(location: 14, length: 5)
            ]
        )
    }

    @Test
    func coordinatorRoutesTabEscapeAndReplacementsToTheSession() async {
        let textView = TextView(string: "0123456789")
        let session = SQLSnippetSession()
        let mounted = makeCoordinator(snippetSession: session)
        session.start(
            textView: textView,
            placeholderRanges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
            ]
        )

        #expect(mounted.coordinator.handleTextViewKeyCommand(.tab, textView: textView))
        #expect(textView.selectedRange() == NSRange(location: 3, length: 1))
        #expect(mounted.coordinator.handleTextViewKeyCommand(.backtab, textView: textView))
        #expect(textView.selectedRange() == NSRange(location: 0, length: 1))

        mounted.coordinator.textView(
            textView,
            didReplaceContentsIn: NSRange(location: 2, length: 0),
            with: "x"
        )
        #expect(session.placeholderRanges == [
            SQLSourceRange(location: 0, length: 1),
            SQLSourceRange(location: 4, length: 1),
        ])

        #expect(mounted.coordinator.handleTextViewKeyCommand(.escape, textView: textView))
        #expect(!session.isActive)
        #expect(!mounted.coordinator.handleTextViewKeyCommand(.escape, textView: textView))

        await mounted.document.close()
    }

    @Test
    func coordinatorTabFallsThroughWithoutAnActiveSession() async {
        let textView = TextView(string: "SELECT 1;")
        let session = SQLSnippetSession()
        let mounted = makeCoordinator(snippetSession: session)

        #expect(!mounted.coordinator.handleTextViewKeyCommand(.tab, textView: textView))
        #expect(!mounted.coordinator.handleTextViewKeyCommand(.backtab, textView: textView))

        await mounted.document.close()
    }

    @Test
    func startHighlightsUnfilledPlaceholdersExceptTheCurrentOne() {
        let mounted = startSession(
            text: "0123456789",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
                SQLSourceRange(location: 9, length: 1),
            ]
        )

        #expect(mounted.session.highlightedRanges == [
            SQLSourceRange(location: 3, length: 1),
            SQLSourceRange(location: 9, length: 1),
        ])
        #expect(
            mounted.textView.emphasisManager?
                .getEmphases(for: SQLSnippetSession.emphasisGroup).count == 2
        )
    }

    @Test
    func jumpingKeepsEveryUnfilledPlaceholderHighlighted() {
        let mounted = startSession(
            text: "0123456789",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
                SQLSourceRange(location: 9, length: 1),
            ]
        )

        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.session.highlightedRanges == [
            SQLSourceRange(location: 0, length: 1),
            SQLSourceRange(location: 9, length: 1),
        ])

        #expect(mounted.session.jumpToPreviousPlaceholder())
        #expect(mounted.session.highlightedRanges == [
            SQLSourceRange(location: 3, length: 1),
            SQLSourceRange(location: 9, length: 1),
        ])
    }

    @Test
    func fillingAPlaceholderRemovesItsHighlight() {
        let mounted = startSession(
            text: "0123456789",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
            ]
        )
        #expect(mounted.session.highlightedRanges == [
            SQLSourceRange(location: 3, length: 1),
        ])

        mounted.session.textDidChange(
            in: NSRange(location: 0, length: 1),
            replacementLength: 1
        )
        #expect(mounted.session.highlightedRanges == [
            SQLSourceRange(location: 3, length: 1),
        ])

        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.session.highlightedRanges.isEmpty)
        #expect(
            mounted.textView.emphasisManager?
                .getEmphases(for: SQLSnippetSession.emphasisGroup).isEmpty
                == true
        )

        #expect(mounted.session.jumpToPreviousPlaceholder())
        #expect(mounted.session.highlightedRanges == [
            SQLSourceRange(location: 3, length: 1),
        ])
    }

    @Test
    func typingAtTheEndOfAnUnfilledPlaceholderMarksItFilled() {
        let mounted = startSession(
            text: "0123456789",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
            ]
        )

        mounted.session.textDidChange(
            in: NSRange(location: 1, length: 0),
            replacementLength: 2
        )

        #expect(mounted.session.placeholderRanges == [
            SQLSourceRange(location: 0, length: 3),
            SQLSourceRange(location: 5, length: 1),
        ])
        #expect(mounted.session.highlightedRanges == [
            SQLSourceRange(location: 5, length: 1),
        ])
    }

    @Test
    func caretInsideAStopDistinguishesItFromOtherHints() {
        let mounted = startSession(
            text: "0123456789",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
                SQLSourceRange(location: 9, length: 1),
            ]
        )

        simulateSelection(NSRange(location: 4, length: 0), in: mounted)

        #expect(mounted.session.isActive)
        #expect(mounted.session.currentIndex == 1)
        // 当前项用单独的描边，其他项保持淡底色。
        #expect(mounted.session.highlightedRanges == [
            SQLSourceRange(location: 0, length: 1),
            SQLSourceRange(location: 9, length: 1),
        ])
        #expect(mounted.textView.emphasisManager?
            .getEmphases(for: SQLSnippetSession.currentEmphasisGroup).map(\.range)
            == [NSRange(location: 3, length: 1)])
    }

    @Test
    func endRemovesPlaceholderHighlights() {
        let mounted = startSession(
            text: "0123456789",
            ranges: [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 3, length: 1),
            ]
        )

        mounted.session.end()

        #expect(mounted.session.highlightedRanges.isEmpty)
        #expect(
            mounted.textView.emphasisManager?
                .getEmphases(for: SQLSnippetSession.emphasisGroup).isEmpty
                == true
        )
    }

    @Test(arguments: [0, 2, 5])
    func insertingAtTheStartMiddleOrEndKeepsTheStopAndNextTab(insertionOffset: Int) {
        let mounted = makeEditingSession()
        mounted.textView.selectionManager.setSelectedRange(NSRange(location: insertionOffset, length: 0))
        mounted.session.selectionDidChange(to: mounted.textView.selectedRange())
        mounted.textView.replaceCharacters(in: NSRange(location: insertionOffset, length: 0), with: "x")
        #expect(mounted.session.placeholderRanges == [
            SQLSourceRange(location: 0, length: 6),
            SQLSourceRange(location: 7, length: 9),
            SQLSourceRange(location: 17, length: 5),
        ])
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 7, length: 9))
        #expect(mounted.session.jumpToPreviousPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 0, length: 6))
        _ = mounted.relay
    }

    @Test
    func replacementBackspaceClearAndRetypeKeepNavigation() {
        let mounted = makeEditingSession()
        mounted.textView.replaceCharacters(in: NSRange(location: 0, length: 5), with: "abc")
        mounted.textView.replaceCharacters(in: NSRange(location: 2, length: 1), with: "")
        #expect(mounted.session.placeholderRanges.first == SQLSourceRange(location: 0, length: 2))
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 3, length: 9))
        #expect(mounted.session.jumpToPreviousPlaceholder())
        mounted.textView.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        #expect(mounted.session.isActive)
        #expect(mounted.session.placeholderRanges.first == SQLSourceRange(location: 0, length: 0))
        mounted.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "字段😀")
        #expect(mounted.session.placeholderRanges.first == SQLSourceRange(location: 0, length: 4))
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.textView.selectedRange() == NSRange(location: 5, length: 9))
        _ = mounted.relay
    }

    @Test
    func adjacentStopsOnlyAssignBoundaryInsertionToTheCurrentStop() {
        let textView = TextView(string: "ab")
        let session = SQLSnippetSession()
        session.start(textView: textView, placeholderRanges: [
            SQLSourceRange(location: 0, length: 1),
            SQLSourceRange(location: 1, length: 1),
        ])
        session.textDidChange(in: NSRange(location: 1, length: 0), replacementLength: 2)
        #expect(session.placeholderRanges == [
            SQLSourceRange(location: 0, length: 3),
            SQLSourceRange(location: 3, length: 1),
        ])
    }

    @Test
    func tabExitsAtTheUpdatedEndOfTheWholeSnippet() {
        let mounted = makeEditingSession()
        mounted.textView.replaceCharacters(in: NSRange(location: 0, length: 5), with: "a")
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.session.jumpToNextPlaceholder())
        #expect(mounted.session.isActive == false)
        #expect(mounted.textView.selectedRange() == NSRange(location: 21, length: 0))
        #expect(mounted.textView.emphasisManager?
            .getEmphases(for: SQLSnippetSession.emphasisGroup).isEmpty == true)
        #expect(mounted.textView.emphasisManager?
            .getEmphases(for: SQLSnippetSession.currentEmphasisGroup).isEmpty == true)
        _ = mounted.relay
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func hintColorsAreSubtleAndTheEditingStopHasABorder(appearance: NSAppearance.Name) throws {
        let mounted = makeEditingSession()
        mounted.textView.appearance = NSAppearance(named: appearance)
        mounted.textView.selectionManager.setSelectedRange(NSRange(location: 2, length: 0))
        mounted.session.selectionDidChange(to: mounted.textView.selectedRange())
        let hints = try #require(mounted.textView.emphasisManager?
            .getEmphases(for: SQLSnippetSession.emphasisGroup))
        #expect(hints.count == 2)
        for hint in hints {
            guard case let .fill(color, border) = hint.style else {
                Issue.record("Pending stops must use a background-only hint")
                return
            }
            #expect(color.alphaComponent <= 0.16)
            #expect(border == nil)
        }
        let current = try #require(mounted.textView.emphasisManager?
            .getEmphases(for: SQLSnippetSession.currentEmphasisGroup).first)
        guard case let .fill(color, border) = current.style else {
            Issue.record("The editing stop must use a background-only border")
            return
        }
        #expect(color.alphaComponent == 0)
        #expect(border != nil)
        _ = mounted.relay
    }

    @Test
    func switchingAppearanceUpdatesHintsWithoutChangingSelectionOrStops() throws {
        let mounted = makeEditingSession()
        mounted.textView.appearance = NSAppearance(named: .aqua)
        let before = try #require(mounted.textView.emphasisManager?
            .getEmphases(for: SQLSnippetSession.emphasisGroup).first)
        mounted.textView.appearance = NSAppearance(named: .darkAqua)
        let after = try #require(mounted.textView.emphasisManager?
            .getEmphases(for: SQLSnippetSession.emphasisGroup).first)
        #expect(before.style != after.style)
        #expect(mounted.textView.selectedRange() == NSRange(location: 0, length: 5))
        #expect(mounted.session.placeholderRanges.count == 3)
        _ = mounted.relay
    }

    @Test
    func rejectsInvalidOrOverlappingInitialStops() {
        let textView = TextView(string: "field")
        let session = SQLSnippetSession()
        session.start(textView: textView, placeholderRanges: [SQLSourceRange(location: 2, length: 9)])
        #expect(session.isActive == false)
        session.start(textView: textView, placeholderRanges: [
            SQLSourceRange(location: 0, length: 4), SQLSourceRange(location: 2, length: 3),
        ])
        #expect(session.isActive == false)
    }

    private func makeEditingSession() -> (
        session: SQLSnippetSession, textView: TextView, relay: SnippetEditRelay
    ) {
        let textView = TextView(string: "field condition value END")
        let session = SQLSnippetSession()
        let relay = SnippetEditRelay(session: session)
        textView.delegate = relay
        session.start(textView: textView, placeholderRanges: [
            SQLSourceRange(location: 0, length: 5),
            SQLSourceRange(location: 6, length: 9),
            SQLSourceRange(location: 16, length: 5),
        ], exitLocation: 25)
        return (session, textView, relay)
    }

    private func startSession(
        text: String,
        ranges: [SQLSourceRange]
    ) -> (session: SQLSnippetSession, textView: TextView) {
        let textView = TextView(string: text)
        let session = SQLSnippetSession()
        session.start(textView: textView, placeholderRanges: ranges)
        return (session, textView)
    }

    /// 模拟编辑器先落新选区、再回调会话的真实顺序；高亮取决于编辑器里的真实选区。
    private func simulateSelection(
        _ range: NSRange,
        in mounted: (session: SQLSnippetSession, textView: TextView)
    ) {
        mounted.textView.selectionManager.setSelectedRange(range)
        mounted.session.selectionDidChange(to: range)
    }

    private func makeCoordinator(
        snippetSession: SQLSnippetSession
    ) -> (
        coordinator: WorkspaceQueryEditorCommandCoordinator,
        document: WorkspaceQueryDocumentModel
    ) {
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "root",
                password: "secret",
                database: nil,
                tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        return (
            WorkspaceQueryEditorCommandCoordinator(
                document: document,
                languageService: WorkspaceSQLLanguageService(),
                snippetSession: snippetSession
            ),
            document
        )
    }
}

@MainActor
private final class SnippetEditRelay: @preconcurrency TextViewDelegate {
    let session: SQLSnippetSession
    init(session: SQLSnippetSession) { self.session = session }
    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        session.textDidChange(in: range, replacementLength: (string as NSString).length)
        session.selectionDidChange(to: textView.selectedRange())
    }
}
