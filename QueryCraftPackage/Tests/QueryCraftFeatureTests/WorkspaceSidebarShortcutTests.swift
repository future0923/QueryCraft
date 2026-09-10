import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceSidebarShortcutTests {
    @Test
    func sidebarShortcutUsesPhysicalSKeyWithChineseInput() throws {
        var toggleCount = 0
        let coordinator = WorkspaceSidebarKeyCommandHandler.Coordinator {
            toggleCount += 1
        }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: 1
            )
        )

        #expect(coordinator.handle(event))
        #expect(toggleCount == 1)
    }

    @Test
    func connectionShortcutUsesPhysicalKKeyWithChineseInput() throws {
        var openCount = 0
        let coordinator = WorkspaceSidebarKeyCommandHandler.Coordinator(
            toggleSidebar: {},
            openConnectionPicker: { openCount += 1 }
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
                keyCode: 40
            )
        )

        #expect(coordinator.handle(event))
        #expect(openCount == 1)
    }
}
