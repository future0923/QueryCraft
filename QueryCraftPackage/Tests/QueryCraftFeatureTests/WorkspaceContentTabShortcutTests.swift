import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceContentTabShortcutTests {
    @Test
    func commandLetterShortcutsUsePhysicalKeysWithChineseInput() throws {
        let recorder = WorkspaceContentTabActionRecorder()
        let coordinator = WorkspaceContentTabKeyCommandHandler.Coordinator(
            actions: recorder.actions
        )
        let commandT = try event(keyCode: 17, modifiers: .command)
        let commandW = try event(keyCode: 13, modifiers: .command)

        #expect(coordinator.handle(commandT))
        #expect(coordinator.handle(commandW))
        #expect(recorder.createdQueryCount == 1)
        #expect(recorder.closedTabCount == 1)
    }

    @Test
    func numberAndBracketShortcutsSelectTabs() throws {
        let recorder = WorkspaceContentTabActionRecorder()
        let coordinator = WorkspaceContentTabKeyCommandHandler.Coordinator(
            actions: recorder.actions
        )

        #expect(coordinator.handle(try event(keyCode: 20, modifiers: .command)))
        #expect(coordinator.handle(try event(keyCode: 30, modifiers: [.command, .shift])))
        #expect(coordinator.handle(try event(keyCode: 33, modifiers: [.command, .shift])))
        #expect(recorder.selectedIndex == 2)
        #expect(recorder.relativeSelections == [1, -1])
    }

    private func event(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}

@MainActor
private final class WorkspaceContentTabActionRecorder {
    var createdQueryCount = 0
    var closedTabCount = 0
    var selectedIndex: Int?
    var relativeSelections: [Int] = []

    var actions: WorkspaceContentTabCommandActions {
        WorkspaceContentTabCommandActions(
            canCreateQuery: true,
            hasContentTabs: true,
            createDocumentTitle: "New Query Tab",
            createQuery: { [weak self] in self?.createdQueryCount += 1 },
            closeSelected: { [weak self] in self?.closedTabCount += 1 },
            selectAtIndex: { [weak self] in self?.selectedIndex = $0 },
            selectRelative: { [weak self] in self?.relativeSelections.append($0) }
        )
    }
}
