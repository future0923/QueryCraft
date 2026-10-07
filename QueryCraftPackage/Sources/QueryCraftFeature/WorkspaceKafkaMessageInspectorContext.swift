import Foundation

struct WorkspaceKafkaMessageInspectorContext: Equatable {
    let topic: String
    let columns: [WorkspaceDatabaseDataColumn]
    let row: WorkspaceDatabaseDataRow?

    init(
        topic: String,
        page: WorkspaceDatabaseDataPage?,
        selectedRowIndexes: IndexSet
    ) {
        self.topic = topic
        columns = page?.columns ?? []
        if selectedRowIndexes.count == 1,
           let rowIndex = selectedRowIndexes.first
        {
            row = page?.row(at: rowIndex)
        } else {
            row = nil
        }
    }

    var searchIdentity: String {
        guard let row else {
            return "kafka-message:\(topic):none"
        }

        let partition = metadataValue(named: "partition", in: row)
            ?? String(row.id)
        let offset = metadataValue(named: "offset", in: row)
            ?? String(row.id)
        return "kafka-message:\(topic):\(partition):\(offset)"
    }

    private func metadataValue(
        named name: String,
        in row: WorkspaceDatabaseDataRow
    ) -> String? {
        guard let column = columns.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return nil
        }
        guard case let .text(value) = row.value(at: column.id), !value.isEmpty else {
            return nil
        }
        return value
    }
}
