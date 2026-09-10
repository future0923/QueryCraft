import AppKit
import SwiftUI

struct WorkspaceDatabaseObjectDetailSegmentedControl: NSViewRepresentable {
    let tabs: [WorkspaceDatabaseObjectDetailTab]
    let objectKind: WorkspaceDatabaseObjectKind
    @Binding var selection: WorkspaceDatabaseObjectDetailTab

    func makeCoordinator() -> Coordinator {
        Coordinator(tabs: tabs, selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: tabs.map { $0.title(for: objectKind) },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectTab(_:))
        )
        control.controlSize = .regular
        control.segmentStyle = .automatic
        control.setAccessibilityIdentifier("databaseObjectDetailTabPicker")
        update(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.tabs = tabs
        context.coordinator.selection = $selection
        guard control.segmentCount == tabs.count else {
            control.segmentCount = tabs.count
            update(control)
            return
        }
        update(control)
    }

    private func update(_ control: NSSegmentedControl) {
        for (index, tab) in tabs.enumerated() {
            control.setLabel(tab.title(for: objectKind), forSegment: index)
            control.setToolTip(help(for: tab, at: index), forSegment: index)
            control.setEnabled(true, forSegment: index)
        }
        control.selectedSegment = tabs.firstIndex(of: selection) ?? -1
        control.sizeToFit()
    }

    private func help(
        for tab: WorkspaceDatabaseObjectDetailTab,
        at index: Int
    ) -> String {
        guard let shortcut = WorkspaceDatabaseObjectDetailTabShortcut
            .commandNumber(at: index)
        else {
            return tab.openTitle(for: objectKind)
        }
        return AppCopy.current.text(
            "\(tab.openTitle(for: objectKind))（⌘\(shortcut.character)）",
            "\(tab.openTitle(for: objectKind)) (⌘\(shortcut.character))"
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var tabs: [WorkspaceDatabaseObjectDetailTab]
        var selection: Binding<WorkspaceDatabaseObjectDetailTab>

        init(
            tabs: [WorkspaceDatabaseObjectDetailTab],
            selection: Binding<WorkspaceDatabaseObjectDetailTab>
        ) {
            self.tabs = tabs
            self.selection = selection
        }

        @objc func selectTab(_ sender: NSSegmentedControl) {
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = tabs[sender.selectedSegment]
        }
    }
}
