import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

struct WorkspaceDatabaseObjectDetailTabTests {
    @Test
    func assignsCommandNumberToEachTab() {
        #expect(WorkspaceDatabaseObjectDetailTab.data.shortcutCharacter == "1")
        #expect(
            WorkspaceDatabaseObjectDetailTab.structure.shortcutCharacter == "2"
        )
        #expect(
            WorkspaceDatabaseObjectDetailTab.indexes.shortcutCharacter == "3"
        )
        #expect(WorkspaceDatabaseObjectDetailTab.options.shortcutCharacter == "4")
        #expect(WorkspaceDatabaseObjectDetailTab.ddl.shortcutCharacter == "5")
        #expect(WorkspaceDatabaseObjectDetailTab.data.shortcutKeyCode == 18)
        #expect(WorkspaceDatabaseObjectDetailTab.structure.shortcutKeyCode == 19)
        #expect(WorkspaceDatabaseObjectDetailTab.indexes.shortcutKeyCode == 20)
        #expect(WorkspaceDatabaseObjectDetailTab.options.shortcutKeyCode == 21)
        #expect(WorkspaceDatabaseObjectDetailTab.ddl.shortcutKeyCode == 23)
        #expect(
            WorkspaceDatabaseObjectDetailTab.available(for: .table)
                == [.data, .structure, .indexes, .options, .ddl]
        )
        #expect(
            WorkspaceDatabaseObjectDetailTab.available(
                for: .elasticsearchIndex
            ) == [.data, .structure]
        )
        #expect(
            WorkspaceDatabaseObjectDetailTab.available(
                for: .elasticsearchAlias
            ) == [.data, .structure]
        )
        #expect(
            WorkspaceDatabaseObjectDetailTab.available(
                for: .elasticsearchDataStream
            ) == [.data, .structure]
        )
        #expect(
            WorkspaceDatabaseObjectDetailTab.structure.title(
                for: .elasticsearchIndex
            ) == "Mapping"
        )
    }

    @Test @MainActor
    func commandNumberUsesPhysicalKeyWhileAppKitGridOwnsFocus() async throws {
        var selectedTabs: [WorkspaceDatabaseObjectDetailTab] = []
        let coordinator = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(
            actions: nil,
            filterPresentationActions: nil,
            objectDetailTabActions: WorkspaceDatabaseObjectDetailTabActions(
                availableTabs: WorkspaceDatabaseObjectDetailTab.available(
                    for: .table
                ),
                select: { selectedTabs.append($0) }
            ),
            isSuspended: false
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: 19
            )
        )

        #expect(coordinator.handle(event))
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }
        #expect(selectedTabs == [.structure])
    }

    @Test @MainActor
    func newTableUsesCommandNumbersForVisibleTabs() async throws {
        var selectedTabs: [WorkspaceDatabaseObjectDetailTab] = []
        let actions = WorkspaceDatabaseObjectDetailTabActions(
            availableTabs: [.structure, .indexes, .options],
            select: { selectedTabs.append($0) }
        )
        #expect(actions.shortcut(for: .structure)?.character == "1")
        #expect(actions.shortcut(for: .indexes)?.character == "2")
        #expect(actions.shortcut(for: .options)?.character == "3")
        #expect(actions.shortcut(for: .data) == nil)
        let coordinator = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(
            actions: nil,
            filterPresentationActions: nil,
            objectDetailTabActions: actions,
            isSuspended: false
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: 19
            )
        )

        #expect(coordinator.handle(event))
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }
        #expect(selectedTabs == [.indexes])
    }

    @Test @MainActor
    func segmentedControlSelectsFromVisibleViewTabs() {
        var selectedTab = WorkspaceDatabaseObjectDetailTab.data
        let coordinator = WorkspaceDatabaseObjectDetailSegmentedControl.Coordinator(
            tabs: [.data, .structure, .ddl],
            selection: Binding(
                get: { selectedTab },
                set: { selectedTab = $0 }
            )
        )
        let control = NSSegmentedControl(
            labels: ["Data", "Structure", "DDL"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        control.selectedSegment = 2

        coordinator.selectTab(control)

        #expect(selectedTab == .ddl)
    }

    @Test @MainActor
    func pendingRequestSelectsTabWhenObjectViewRegisters() {
        let selection = makeSelection(kind: .table)
        let registry = WorkspaceDatabaseObjectDetailTabRegistry()
        var selectedTabs: [WorkspaceDatabaseObjectDetailTab] = []

        registry.request(.structure, for: selection)
        registry.update(
            makeActions(selection: selection) { selectedTabs.append($0) },
            for: .databaseObject(selection)
        )

        #expect(selectedTabs == [.structure])
    }

    @Test @MainActor
    func registeredObjectViewReceivesRequestImmediately() {
        let selection = makeSelection(kind: .table)
        let registry = WorkspaceDatabaseObjectDetailTabRegistry()
        var selectedTabs: [WorkspaceDatabaseObjectDetailTab] = []
        registry.update(
            makeActions(selection: selection) { selectedTabs.append($0) },
            for: .databaseObject(selection)
        )

        registry.request(.ddl, for: selection)

        #expect(selectedTabs == [.ddl])
    }

    @Test @MainActor
    func viewRejectsUnavailableIndexesRequest() {
        let selection = makeSelection(kind: .view)
        let registry = WorkspaceDatabaseObjectDetailTabRegistry()
        var selectedTabs: [WorkspaceDatabaseObjectDetailTab] = []
        registry.update(
            makeActions(selection: selection) { selectedTabs.append($0) },
            for: .databaseObject(selection)
        )

        registry.request(.indexes, for: selection)

        #expect(selectedTabs.isEmpty)
    }

    @MainActor
    private func makeActions(
        selection: WorkspaceDatabaseObjectSelection,
        select: @escaping @MainActor @Sendable (
            WorkspaceDatabaseObjectDetailTab
        ) -> Void
    ) -> WorkspaceDatabaseObjectDetailTabActions {
        WorkspaceDatabaseObjectDetailTabActions(
            availableTabs: WorkspaceDatabaseObjectDetailTab.available(
                for: selection.kind
            ),
            select: select
        )
    }

    private func makeSelection(
        kind: WorkspaceDatabaseObjectKind
    ) -> WorkspaceDatabaseObjectSelection {
        WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: kind == .table ? "users" : "active_users",
            kind: kind
        )
    }
}
