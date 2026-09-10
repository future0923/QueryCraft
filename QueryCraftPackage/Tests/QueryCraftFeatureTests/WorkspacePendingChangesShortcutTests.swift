import AppKit
import Testing

@testable import QueryCraftFeature

@MainActor
struct WorkspacePendingChangesShortcutTests {
    @Test
    func shiftCommandPUsesPhysicalKeyWithChineseInputSource() throws {
        let recorder = WorkspacePendingChangesActionRecorder()
        let coordinator = WorkspacePendingChangesKeyCommandHandler.Coordinator(
            actions: recorder.actions
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: 35
            )
        )

        #expect(coordinator.handle(event))
        #expect(recorder.previewCount == 1)
    }
}

@MainActor
private final class WorkspacePendingChangesActionRecorder {
    var previewCount = 0

    var actions: WorkspacePendingChangesActions {
        WorkspacePendingChangesActions(
            hasChanges: true,
            statements: [
                WorkspaceSQLPreviewStatement(
                    tokens: [
                        WorkspaceSQLPreviewToken(
                            text: "UPDATE",
                            kind: .keyword
                        ),
                    ]
                ),
            ],
            isCommitting: false,
            discard: {},
            preview: { [weak self] in self?.previewCount += 1 },
            commit: {}
        )
    }
}
