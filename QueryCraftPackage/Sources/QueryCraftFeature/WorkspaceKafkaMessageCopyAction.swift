import AppKit

struct WorkspaceKafkaMessageCopyAction {
    let topic: String
    let open: @MainActor (WorkspaceKafkaMessageReference) -> Void

    @MainActor
    func menuItem(row: WorkspaceDatabaseDataRow, columns: [WorkspaceDatabaseDataColumn]) -> NSMenuItem? {
        func text(_ name: String) -> String? {
            guard let column = columns.first(where: { $0.name == name }),
                  case .text(let value) = row.value(at: column.id) else { return nil }
            return value
        }
        guard let partitionText = text("partition"), let partition = Int32(partitionText), partition >= 0,
              let offsetText = text("offset"), let offset = Int64(offsetText), offset >= 0 else { return nil }
        // Capture the location and callback while constructing the menu. Live
        // buffering or a tab change must not retarget the action to another row.
        return WorkspaceKafkaCopyMenuItem(reference: .init(topic: topic, partition: partition, offset: offset), open: open)
    }
}

@MainActor
private final class WorkspaceKafkaCopyMenuItem: NSMenuItem {
    let reference: WorkspaceKafkaMessageReference
    let open: @MainActor (WorkspaceKafkaMessageReference) -> Void

    init(reference: WorkspaceKafkaMessageReference, open: @escaping @MainActor (WorkspaceKafkaMessageReference) -> Void) {
        self.reference = reference; self.open = open
        super.init(title: AppCopy.current.text("复制为新消息…", "Copy as New Message…"),
                   action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc func invoke() { open(reference) }
}
