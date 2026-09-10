import AppKit
import Testing
@testable import QueryCraftFeature

struct WorkspaceGridSelectionAppearanceTests {
    @Test @MainActor
    func schemaGridFillsTheViewportWithoutStretchingItsLastColumn() {
        #expect(
            WorkspaceGridViewportClipView.documentWidth(
                viewportWidth: 320,
                naturalContentWidth: 188
            ) == 320
        )
        #expect(
            WorkspaceGridViewportClipView.documentWidth(
                viewportWidth: 320,
                naturalContentWidth: 640
            ) == 640
        )
    }

    @Test @MainActor
    func dataGridActiveCellUsesTheSystemAccentInsteadOfOrange() {
        #expect(
            WorkspaceDatabaseDataRowView.activeCellIndicatorColor
                == .controlAccentColor
        )
        #expect(
            WorkspaceDatabaseDataRowView.activeCellIndicatorColor
                != .systemOrange
        )
    }

    @Test @MainActor
    func schemaInlineEditorReachesTheFullColumnTrailingEdge() {
        let frame = WorkspaceDatabaseSchemaGridCoordinator.inlineEditorFrame(
            rowRect: NSRect(x: 0, y: 72, width: 700, height: 24),
            columnRect: NSRect(x: 184, y: 0, width: 284, height: 700)
        )

        #expect(frame.minX == 184)
        #expect(frame.maxX == 468)
        #expect(frame.minY == 73)
        #expect(frame.maxY == 95)
    }

    @Test @MainActor
    func schemaEditingSuppressesOnlyTheCoveredActiveCellIndicator() {
        let edited = WorkspaceGridCoordinate(row: 2, column: 8)
        let other = WorkspaceGridCoordinate(row: 2, column: 7)

        #expect(
            WorkspaceDatabaseSchemaRowView.shouldDrawActiveCellIndicator(
                active: edited,
                suppressed: nil,
                coordinate: edited,
                isKeyWindow: true
            )
        )
        #expect(
            !WorkspaceDatabaseSchemaRowView.shouldDrawActiveCellIndicator(
                active: edited,
                suppressed: edited,
                coordinate: edited,
                isKeyWindow: true
            )
        )
        #expect(
            WorkspaceDatabaseSchemaRowView.shouldDrawActiveCellIndicator(
                active: edited,
                suppressed: other,
                coordinate: edited,
                isKeyWindow: true
            )
        )
        #expect(
            !WorkspaceDatabaseSchemaRowView.shouldDrawActiveCellIndicator(
                active: edited,
                suppressed: nil,
                coordinate: edited,
                isKeyWindow: false
            )
        )
    }

    @Test @MainActor
    func selectionTextUsesSystemSemanticColors() {
        #expect(
            WorkspaceDatabaseDataRowView.selectedTextColor(
                isEmphasized: true
            ) == .alternateSelectedControlTextColor
        )
        #expect(
            WorkspaceDatabaseDataRowView.selectedTextColor(
                isEmphasized: false
            ) == .unemphasizedSelectedTextColor
        )
        #expect(
            WorkspaceDatabaseDataRowView.selectedPlaceholderTextColor(
                isEmphasized: true
            ) != WorkspaceDatabaseDataRowView.selectedTextColor(
                isEmphasized: true
            )
        )
        let placeholderAttributes = WorkspaceDatabaseDataRowView
            .selectedCellAttributes(
                font: WorkspaceGridMetrics.cellFont,
                isEmphasized: true,
                isPlaceholder: true
            )
        let valueAttributes = WorkspaceDatabaseDataRowView
            .selectedCellAttributes(
                font: WorkspaceGridMetrics.cellFont,
                isEmphasized: true,
                isPlaceholder: false
            )
        #expect(
            placeholderAttributes[.foregroundColor] as? NSColor
                == WorkspaceDatabaseDataRowView.selectedPlaceholderTextColor(
                    isEmphasized: true
                )
        )
        #expect(
            placeholderAttributes[.foregroundColor] as? NSColor
                != valueAttributes[.foregroundColor] as? NSColor
        )
        #expect(
            WorkspaceDatabaseDataRowView.draftBackgroundColor(
                isDraftRow: true,
                isEditing: true,
                isWindowKey: true,
                isDarkAppearance: true
            ) == .selectedContentBackgroundColor
        )
        #expect(
            WorkspaceDatabaseDataRowView.draftBackgroundColor(
                isDraftRow: true,
                isEditing: true,
                isWindowKey: false,
                isDarkAppearance: true
            ) == WorkspaceDatabaseDataRowView.pendingDraftBackgroundColor(
                isDarkAppearance: true
            )
        )
        #expect(
            WorkspaceDatabaseDataRowView.draftBackgroundColor(
                isDraftRow: true,
                isEditing: false,
                isWindowKey: true,
                isDarkAppearance: false
            ) == WorkspaceDatabaseDataRowView.pendingDraftBackgroundColor(
                isDarkAppearance: false
            )
        )
        #expect(
            WorkspaceDatabaseDataRowView.pendingDraftBackgroundColor(
                isDarkAppearance: true
            ) != WorkspaceDatabaseDataRowView.pendingDraftBackgroundColor(
                isDarkAppearance: false
            )
        )
        #expect(
            WorkspaceDatabaseDataRowView.pendingDraftBackgroundColor(
                isDarkAppearance: false
            ).alphaComponent == 0.45
        )
        #expect(
            WorkspaceDatabaseDataRowView.pendingDraftBackgroundColor(
                isDarkAppearance: true
            ).alphaComponent == 0.39
        )
        #expect(
            WorkspaceDatabaseDataRowView.pendingUpdateBackgroundColor(
                isDarkAppearance: false
            ).alphaComponent == 0.24
        )
        #expect(
            WorkspaceDatabaseDataRowView.pendingUpdateBackgroundColor(
                isDarkAppearance: true
            ).alphaComponent == 0.30
        )
        #expect(
            WorkspaceDatabaseDataRowView.pendingUpdateBackgroundColor(
                isDarkAppearance: false
            ) != WorkspaceDatabaseDataRowView.pendingDraftBackgroundColor(
                isDarkAppearance: false
            )
        )
        #expect(
            WorkspaceDatabaseDataRowView.draftBackgroundColor(
                isDraftRow: false,
                isEditing: false,
                isWindowKey: true,
                isDarkAppearance: true
            ) == nil
        )
    }
}
