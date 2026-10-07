import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor @Suite("Kafka topic configuration", .timeLimit(.minutes(1)))
struct WorkspaceKafkaTopicConfigurationTests {
    @Test("Definite broker validation rejection preserves an editable draft")
    func rejectedValueCanBeCorrected() async {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        editor.receive(details())
        editor.update("max.message.bytes", value: "invalid")
        await editor.save(using: { _ in throw WorkspaceKafkaTopicConfigurationError.rejected("Invalid integer") }, read: {
            Issue.record("Rejected writes do not need a readback")
            return details()
        })
        #expect(editor.error != nil && editor.needsReload == false && editor.hasChanges)
        editor.update("max.message.bytes", value: "2097152")
        #expect(editor.canCommit && editor.error == nil)
    }

    @Test("Inline edits freeze the property name across filtering and Escape restores a pending default reset")
    func gridEditingIdentity() throws {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        editor.receive(details())
        editor.update("max.message.bytes", inheritsDefault: true)
        let filtered = WorkspaceKafkaConfigurationGrid(editor: editor, filter: "max.message", loading: false)
        let target = WorkspaceDatabaseDataCellEditTarget(rowIndex: 0, dataColumnIndex: 1, columns: [], row: .init(id: 0, values: []))
        let context = try #require(filtered.prepareEdit(target))
        #expect(context.columnName == "max.message.bytes" && context.initialMutation == .useDefault)
        let unfiltered = WorkspaceKafkaConfigurationGrid(editor: editor, filter: "", loading: false)
        unfiltered.updateEdit(context, .value("2000000"))
        #expect(try editor.request().changes.first?.id == "max.message.bytes")
        unfiltered.updateEdit(context, context.initialMutation)
        #expect(try editor.request().changes.first?.value == nil)
        #expect(editor.fields.first(where: { $0.id == "cleanup.policy" })?.value == "delete")
    }

    @Test("All returned writable properties edit directly and revert to inherited values")
    func inlineEditing() throws {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        editor.receive(details())
        editor.update("retention.ms", value: "1000")
        #expect(try editor.request().changes.first?.value == "1000")
        #expect(editor.fields.first(where: { $0.id == "retention.ms" })?.inheritsDefault == false)
        editor.update("retention.ms", value: "604800000")
        #expect(editor.changes.isEmpty)
        editor.update("retention.ms", value: "2000")
        editor.update("retention.ms", inheritsDefault: true)
        #expect(editor.fields.first(where: { $0.id == "retention.ms" })?.value == "604800000")
        #expect(editor.hasChanges == false)
        editor.update("max.message.bytes", value: "2097152")
        #expect(try editor.request().changes.map(\.id) == ["max.message.bytes"])
        editor.update("max.message.bytes", inheritsDefault: true)
        #expect(try editor.request().changes.first?.value == nil)
        editor.revert("max.message.bytes")
        #expect(editor.hasChanges == false)
    }

    @Test("Unknown, read-only and sensitive fields cannot be staged; unset values are not phantom edits")
    func readOnlyFields() {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        editor.receive(.init(partitions: [], configurations: [
            .init(name: "version", value: "3.0", isDefault: false, isReadOnly: true),
            .init(name: "secret", value: "hidden", isDefault: false, isSensitive: true),
            .init(name: "unset", value: nil, isDefault: false)
        ]))
        editor.update("version", value: "4.0")
        editor.update("secret", value: "changed")
        editor.update("unknown", value: "1")
        #expect(editor.hasChanges == false)
        #expect(editor.fields.first(where: { $0.id == "secret" })?.value == "")
    }

    @Test("Refresh preserves drafts and their conflict baseline, and discard adopts the latest server values")
    func refreshDraft() throws {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        editor.receive(details())
        editor.update("retention.ms", value: "1000")
        editor.receive(details(retention: "2000", inherited: false))
        let request = try editor.request()
        #expect(request.changes.first?.original.value == "604800000")
        #expect(request.changes.first?.value == "1000")
        #expect(throws: WorkspaceKafkaTopicConfigurationError.self) { try request.validateCurrent(details(retention: "2000", inherited: false).configurations) }
        editor.revert("retention.ms")
        #expect(editor.hasChanges == false)
        #expect(editor.fields.first(where: { $0.id == "retention.ms" })?.value == "2000")
    }

    @Test("A property removed by refresh stays staged and cannot silently target another row")
    func removedProperty() throws {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        editor.receive(details())
        editor.update("max.message.bytes", value: "2097152")
        editor.receive(.init(partitions: [], configurations: details().configurations.filter { $0.name != "max.message.bytes" }))
        #expect(try editor.request().changes.first?.id == "max.message.bytes")
        #expect(editor.fields.first(where: { $0.id == "max.message.bytes" })?.value == "2097152")
        editor.discard()
        #expect(editor.fields.contains { $0.id == "max.message.bytes" } == false)
    }

    @Test("String and empty values survive generic configuration editing and readback")
    func stringValues() async {
        let original = WorkspaceKafkaTopicConfiguration(name: "leader.replication.throttled.replicas", value: "0:1", isDefault: false)
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        editor.receive(.init(partitions: [], configurations: [original]))
        editor.update(original.name, value: "")
        await editor.save(using: { request in #expect(request.changes.first?.value == "") }, read: {
            .init(partitions: [], configurations: [.init(name: original.name, value: "", isDefault: false)])
        })
        #expect(editor.didSave && editor.hasChanges == false)
        let preview = WorkspacePendingChangesPreview.kafka(topic: "events", changes: [.init(original: original, value: "")])
        #expect(preview.isEmpty == false && preview.isKafka)
    }

    private func details(retention: String = "604800000", inherited: Bool = true) -> WorkspaceKafkaTopicDetails {
        .init(partitions: [], configurations: [
            .init(name: "retention.ms", value: retention, isDefault: inherited),
            .init(name: "retention.bytes", value: "-1", isDefault: true),
            .init(name: "cleanup.policy", value: "delete", isDefault: false),
            .init(name: "max.message.bytes", value: "1000012", isDefault: false)
        ])
    }

    @Test("Unchanged and inherited fields are omitted; only edited overrides are submitted")
    func incrementalChanges() async throws {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        await editor.load { details() }
        #expect(editor.changes.isEmpty)
        editor.update("retention.ms", value: " 86400000 ", inheritsDefault: false)
        let request = try editor.request()
        #expect(request.topic == "events")
        #expect(request.changes.count == 1)
        #expect(request.changes.first?.value == "86400000")
        #expect(request.changes.first?.id == "retention.ms")
        editor.update("retention.ms", inheritsDefault: true)
        #expect(editor.changes.isEmpty)
        editor.update("cleanup.policy", inheritsDefault: true)
        #expect(try editor.request().changes == [.init(original: details().configurations[2], value: nil)])
    }

    @Test("Rejects invalid retention without dispatching", arguments: ["-2", "1.5", "", "9223372036854775808", "1e3", "abc"])
    func invalidRetention(_ value: String) async {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        await editor.load { details() }
        editor.update("retention.ms", value: value, inheritsDefault: false)
        #expect(editor.validationMessage != nil)
        await editor.save(using: { _ in Issue.record("Invalid request must not be sent") }, read: { details() })
        #expect(editor.error != nil)
    }

    @Test("Accepts retention boundaries", arguments: ["-1", "0", "9223372036854775807"])
    func retentionBoundaries(_ value: String) async throws {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        await editor.load { details() }
        editor.update("retention.ms", value: value, inheritsDefault: false)
        #expect(throws: Never.self) { try editor.request().validate() }
    }

    @Test("Rejects changed source or value and read-only configuration properties")
    func conflicts() throws {
        let original = details().configurations[0]
        let request = WorkspaceKafkaTopicConfigurationRequest(topic: "events", changes: [.init(original: original, value: "1000")])
        #expect(throws: Never.self) { try request.validateCurrent(details().configurations) }
        #expect(throws: WorkspaceKafkaTopicConfigurationError.self) { try request.validateCurrent(details(retention: "1000").configurations) }
        #expect(throws: WorkspaceKafkaTopicConfigurationError.self) { try request.validateCurrent(details(inherited: false).configurations) }
        #expect(throws: WorkspaceKafkaTopicConfigurationError.self) {
            try WorkspaceKafkaTopicConfigurationRequest(topic: "events", changes: [.init(original: .init(name: "message.format.version", value: "3.0", isDefault: false, isReadOnly: true), value: "5")]).validate()
        }
    }

    @Test("Failed load retains displayed values and blocks saving until reread succeeds")
    func failedLoad() async {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        await editor.load { details() }
        await editor.load { .init(partitions: [], configurations: [], configurationError: "ACL") }
        #expect(editor.fields.count == 4 && editor.needsReload)
        await editor.save(using: { _ in Issue.record("Unreadable configuration must not be sent") }, read: { details() })
        await editor.load { details() }
        #expect(editor.needsReload == false && editor.error == nil)
    }

    @Test("Successful write rereads, verifies and resets the preview")
    func saveAndVerify() async {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        await editor.load { details() }
        editor.update("retention.ms", value: "1000", inheritsDefault: false)
        var writes = 0
        await editor.save(using: { request in writes += 1; #expect(request.changes.count == 1) },
                          read: { details(retention: "1000", inherited: false) })
        #expect(writes == 1 && editor.didSave && editor.changes.isEmpty)
        #expect(editor.fields.first(where: { $0.id == "retention.ms" })?.value == "1000")
    }

    @Test("Write failure and readback failure require reread before another save", arguments: [false, true])
    func uncertainWrite(_ acknowledged: Bool) async {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        await editor.load { details() }
        editor.update("retention.ms", value: "1000", inheritsDefault: false)
        var writes = 0
        await editor.save(using: { _ in
            writes += 1
            if !acknowledged { throw WorkspaceSessionError.notConnected }
        }, read: { throw WorkspaceSessionError.notConnected })
        #expect(editor.needsReload && editor.didSave == false && editor.error != nil)
        await editor.save(using: { _ in writes += 1 }, read: { details() })
        #expect(writes == 1)
        await editor.load { details(retention: "1000", inherited: false) }
        #expect(editor.needsReload == false && editor.changes.isEmpty)
    }

    @Test("Readback mismatch is not reported as success")
    func mismatch() async {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        await editor.load { details() }
        editor.update("retention.ms", value: "1000", inheritsDefault: false)
        await editor.save(using: { _ in }, read: { details() })
        #expect(editor.didSave == false && editor.error != nil)
        #expect(editor.fields.first(where: { $0.id == "retention.ms" })?.value == "604800000")
    }

    @Test("Duplicate save and changes during an outstanding write are ignored")
    func concurrentSave() async {
        let editor = WorkspaceKafkaTopicConfigurationModel(topic: "events")
        await editor.load { details() }
        editor.update("retention.ms", value: "1000", inheritsDefault: false)
        let gate = AsyncStream<Void>.makeStream()
        var writes = 0
        let task = Task {
            await editor.save(using: { _ in
                writes += 1
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
            }, read: { details(retention: "1000", inherited: false) })
        }
        while !editor.isBusy { await Task.yield() }
        editor.update("retention.ms", value: "2000")
        await editor.save(using: { _ in writes += 1 }, read: { details() })
        #expect(writes == 1 && editor.fields.first(where: { $0.id == "retention.ms" })?.value == "1000")
        gate.continuation.finish()
        await task.value
        #expect(editor.didSave && editor.isBusy == false)
    }
}
