import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceDatabaseDataFilterKeyCommandHandlerTests {
    enum Shortcut: CaseIterable, Sendable {
        case add, remove, apply, up, down, column, operation, toggle, close

        var keyCode: UInt16 {
            switch self {
            case .add, .remove: 34
            case .apply: 36
            case .up: 126
            case .down: 125
            case .column: 123
            case .operation: 124
            case .toggle: 11
            case .close: 53
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .remove: [.command, .shift]
            case .close: []
            default: .command
            }
        }

        var actionName: String { String(describing: self) }
    }

    @Test(arguments: Shortcut.allCases, [false, true])
    func everyFilterShortcutRespectsFocus(shortcut: Shortcut, focused: Bool) throws {
        let probe = Probe()
        let handler = WorkspaceDatabaseDataFilterKeyCommandHandler.Coordinator(
            actions: probe.actions, isFocused: focused
        )
        #expect(handler.handle(try event(shortcut.keyCode, modifiers: shortcut.modifiers)) == focused)
        #expect(probe.performed == (focused ? [shortcut.actionName] : []))
    }

    @Test(arguments: Shortcut.allCases)
    func disabledShortcutNeverFallsThroughToAnotherAction(shortcut: Shortcut) throws {
        let probe = Probe()
        probe.enabled = false
        let handler = WorkspaceDatabaseDataFilterKeyCommandHandler.Coordinator(
            actions: probe.actions, isFocused: true
        )
        #expect(handler.handle(try event(shortcut.keyCode, modifiers: shortcut.modifiers)) == false)
        #expect(probe.performed.isEmpty)
    }

    @Test(arguments: [Shortcut.add, .remove, .toggle])
    func characterShortcutsUsePhysicalKeysWithChineseInput(shortcut: Shortcut) throws {
        let probe = Probe()
        let handler = WorkspaceDatabaseDataFilterKeyCommandHandler.Coordinator(
            actions: probe.actions, isFocused: true
        )
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shortcut.modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: "中", charactersIgnoringModifiers: "中",
            isARepeat: false, keyCode: shortcut.keyCode))
        #expect(handler.handle(key))
        #expect(probe.performed == [shortcut.actionName])
    }

    @Test(arguments: Shortcut.allCases)
    func extraModifiersDoNotTriggerFilterCommands(shortcut: Shortcut) throws {
        let probe = Probe()
        let handler = WorkspaceDatabaseDataFilterKeyCommandHandler.Coordinator(
            actions: probe.actions, isFocused: true
        )
        #expect(handler.handle(try event(shortcut.keyCode,
            modifiers: shortcut.modifiers.union(.option))) == false)
        #expect(handler.handle(try event(shortcut.keyCode,
            modifiers: shortcut.modifiers.union(.control))) == false)
        #expect(probe.performed.isEmpty)
    }

    @Test(arguments: [UInt16(123), 124, 125, 126, 36, 34, 11, 53])
    func unfocusedFilterNeverConsumesWindowKeys(keyCode: UInt16) throws {
        let probe = Probe()
        let handler = WorkspaceDatabaseDataFilterKeyCommandHandler.Coordinator(
            actions: probe.actions, isFocused: false
        )
        #expect(handler.handle(try event(keyCode)) == false)
        #expect(probe.performed.isEmpty)
    }

    @Test(arguments: [UInt16(123), 124, 125, 126], [false, true])
    func textEditorOwnsCommandArrowMovement(keyCode: UInt16, extendsSelection: Bool) throws {
        let probe = Probe()
        // Even a stale SwiftUI focus update must not override an AppKit editor.
        let handler = WorkspaceDatabaseDataFilterKeyCommandHandler.Coordinator(
            actions: probe.actions, isFocused: true
        )
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: .init(x: 10, y: 20, width: 350, height: 24))
        field.stringValue = "merchant code"
        window.contentView?.addSubview(field)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        defer { window.makeFirstResponder(nil); window.close() }
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        let modifiers: NSEvent.ModifierFlags = extendsSelection ? [.command, .shift] : .command
        let key = try event(keyCode, modifiers: modifiers, windowNumber: window.windowNumber)
        #expect(handler.handle(key) == false)
        #expect(probe.performed.isEmpty)
        editor.interpretKeyEvents([key])
        let end = [UInt16(124), 125].contains(keyCode) ? editor.string.utf16.count : 0
        let expected = extendsSelection
            ? NSRange(location: min(6, end), length: abs(end - 6))
            : NSRange(location: end, length: 0)
        #expect(editor.selectedRange() == expected)
        #expect(window.firstResponder === editor)
    }

    @Test(arguments: [UInt16(123), 124, 125, 126])
    func filterControlsKeepTheirLocalNavigation(keyCode: UInt16) throws {
        let probe = Probe()
        let handler = WorkspaceDatabaseDataFilterKeyCommandHandler.Coordinator(
            actions: probe.actions, isFocused: true
        )
        #expect(handler.handle(try event(keyCode)))
        let expected: String = switch keyCode {
        case 123: "column"
        case 124: "operation"
        case 125: "down"
        default: "up"
        }
        #expect(probe.performed == [expected])
        probe.performed = []
        #expect(handler.handle(try event(keyCode, modifiers: [.command, .shift])) == false)
        #expect(handler.handle(try event(keyCode, modifiers: [.command, .option])) == false)
        #expect(probe.performed.isEmpty)
    }

    @Test
    func inactiveObjectDoesNotHandleFilterOrRowShortcuts() throws {
        let probe = Probe()
        let handler = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(
            actions: .init(selectedRowIndexes: IndexSet(integer: 0), canAddRow: true,
                canDuplicateRow: true, canDeleteRow: true,
                addRow: { probe.performed.append("row add") },
                duplicateRow: { _ in probe.performed.append("row duplicate") },
                deleteRows: { _ in probe.performed.append("row delete") }),
            filterPresentationActions: .init(toggle: { probe.performed.append("filter") }),
            objectDetailTabActions: .init(availableTabs: [.data, .structure],
                select: { _ in probe.performed.append("tab") }),
            isSuspended: false, isFocused: false)
        #expect(handler.handle(try event(34)) == false)
        #expect(handler.handle(try event(2)) == false)
        #expect(handler.handle(try event(51, modifiers: [])) == false)
        #expect(handler.handle(try event(18)) == false)
        #expect(handler.handle(try event(3, modifiers: [.command, .shift])) == false)
        #expect(probe.performed.isEmpty)
    }

    private func event(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = .command,
        windowNumber: Int = 0
    ) throws -> NSEvent {
        let codePoints: [UInt16: UInt32] = [123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700]
        let character = codePoints[keyCode].flatMap(UnicodeScalar.init).map(String.init)
            ?? [34: "i", 11: "b", 36: "\r", 53: "\u{1B}"][keyCode] ?? ""
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: keyCode))
    }

    @MainActor private final class Probe {
        var performed: [String] = []
        var enabled = true
        var actions: WorkspaceDatabaseDataFilterCommandActions {
            .init(canAddCondition: enabled, canRemoveCondition: enabled, canApplyAll: enabled,
                canNavigateConditions: enabled, canEditActiveCondition: enabled,
                canToggleCondition: enabled, canCloseFilter: enabled,
                addCondition: { self.performed.append("add") },
                removeCondition: { self.performed.append("remove") },
                applyAll: { self.performed.append("apply") },
                moveUp: { self.performed.append("up") },
                moveDown: { self.performed.append("down") },
                openColumnPicker: { self.performed.append("column") },
                openOperatorPicker: { self.performed.append("operation") },
                toggleCondition: { self.performed.append("toggle") },
                close: { self.performed.append("close") })
        }
    }
}
