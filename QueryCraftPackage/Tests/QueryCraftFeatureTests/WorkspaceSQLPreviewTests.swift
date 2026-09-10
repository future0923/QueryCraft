import AppKit
import Testing

@testable import QueryCraftFeature

@MainActor
struct WorkspaceSQLPreviewTests {
    @Test
    func escapeDismissesPreviewButReturnDoesNot() throws {
        let escape = try #require(makeKeyEvent(keyCode: 53, characters: "\u{1b}"))
        let returnKey = try #require(makeKeyEvent(keyCode: 36, characters: "\r"))

        #expect(
            WorkspaceSQLPreviewKeyCommandHandler.Coordinator.shouldDismiss(
                for: escape
            )
        )
        #expect(
            !WorkspaceSQLPreviewKeyCommandHandler.Coordinator.shouldDismiss(
                for: returnKey
            )
        )
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        characters: String
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
