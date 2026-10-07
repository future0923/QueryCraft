import Foundation
import Observation

@MainActor @Observable
final class WorkspaceKafkaTopicConfigurationModel {
    struct Field: Identifiable {
        let original: WorkspaceKafkaTopicConfiguration
        var value: String
        var inheritsDefault: Bool
        var id: String { original.name }
    }

    let topic: String
    let lifetime = WorkspaceDataCellEditingLifetime()
    private var latest: WorkspaceKafkaTopicDetails?
    var hasChanges: Bool { !changes.isEmpty }
    var canCommit: Bool { hasChanges && !isBusy && !needsReload && validationMessage == nil }
    private(set) var fields: [Field] = []
    private(set) var isBusy = false
    private(set) var needsReload = true
    private(set) var error: String?
    private(set) var didSave = false

    init(topic: String) { self.topic = topic }

    func update(_ id: String, value: String? = nil, inheritsDefault: Bool? = nil) {
        guard !isBusy, !needsReload, let index = fields.firstIndex(where: { $0.id == id }) else { return }
        guard !fields[index].original.isReadOnly, !fields[index].original.isSensitive else { return }
        if let value {
            fields[index].value = value
            // Editing inherited values automatically creates an override. Returning
            // to the original value also restores its original source (including Esc).
            fields[index].inheritsDefault = fields[index].original.isDefault && value == (fields[index].original.value ?? "")
        }
        if let inheritsDefault {
            fields[index].inheritsDefault = inheritsDefault
            if inheritsDefault { fields[index].value = fields[index].original.value ?? "" }
        }
        didSave = false
        error = nil
    }

    var changes: [WorkspaceKafkaTopicConfigurationChange] {
        fields.compactMap { field in
            let value = ["retention.ms", "retention.bytes", "cleanup.policy"].contains(field.id)
                ? field.value.trimmingCharacters(in: .whitespacesAndNewlines) : field.value
            if field.inheritsDefault {
                return field.original.isDefault ? nil : .init(original: field.original, value: nil)
            }
            guard field.original.isDefault || value != (field.original.value ?? "") else { return nil }
            return .init(original: field.original, value: value)
        }
    }

    var validationMessage: String? {
        guard !changes.isEmpty else { return nil }
        do { try request().validate(); return nil } catch { return error.localizedDescription }
    }

    func request() throws -> WorkspaceKafkaTopicConfigurationRequest {
        guard !needsReload else { throw WorkspaceKafkaTopicConfigurationError.unavailable }
        let request = WorkspaceKafkaTopicConfigurationRequest(topic: topic, changes: changes)
        try request.validate()
        return request
    }

    func load(using read: () async throws -> WorkspaceKafkaTopicDetails) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        didSave = false
        do {
            let details = try await read()
            try Task.checkCancellation()
            try accept(details)
        } catch {
            needsReload = true
            self.error = error.localizedDescription
        }
    }

    func save(using write: (WorkspaceKafkaTopicConfigurationRequest) async throws -> Void,
              read: () async throws -> WorkspaceKafkaTopicDetails) async {
        guard !isBusy else { return }
        lifetime.finish(commit: true)
        let request: WorkspaceKafkaTopicConfigurationRequest
        do { request = try self.request() } catch { self.error = error.localizedDescription; return }
        isBusy = true
        didSave = false
        error = nil
        defer { isBusy = false }
        var acknowledged = false
        do {
            try await write(request)
            acknowledged = true
            let details = try await read()
            try accept(details)
            let matches = request.changes.allSatisfy { change in
                guard let actual = details.configurations.first(where: { $0.name == change.id }) else { return false }
                if let value = change.value {
                    if change.id == "cleanup.policy" {
                        return !actual.isDefault && Set((actual.value ?? "").split(separator: ",")) == Set(value.split(separator: ","))
                    }
                    if ["retention.ms", "retention.bytes"].contains(change.id) {
                        return !actual.isDefault && Int64(actual.value ?? "") == Int64(value)
                    }
                    return !actual.isDefault && actual.value == value
                }
                return actual.isDefault
            }
            if matches { didSave = true }
            else { error = AppCopy.current.text("请求已提交，但回读值与预期不一致。已显示当前配置，请检查。", "Submitted, but the reread values differ from the requested changes. Review the current configuration.") }
        } catch {
            // An uncertain admin result must never become a blind retry.
            if !acknowledged, let configurationError = error as? WorkspaceKafkaTopicConfigurationError,
               case .rejected = configurationError {
                self.error = error.localizedDescription
                return
            }
            needsReload = true
            let prefix = acknowledged
                ? AppCopy.current.text("已保存，但回读失败。请重新读取确认：", "Saved, but rereading failed. Reload to verify: ")
                : AppCopy.current.text("修改未确认，请重新读取后确认当前值：", "Change not confirmed. Reload to check current values: ")
            self.error = prefix + error.localizedDescription
        }
    }

    func receive(_ details: WorkspaceKafkaTopicDetails) {
        guard !isBusy else { return }
        do {
            guard details.configurationError == nil else { throw WorkspaceKafkaTopicConfigurationError.unavailable }
            latest = details
            if hasChanges {
                // Refresh updates untouched rows without replacing drafts or their
                // original snapshots, so conflicts remain detectable at commit time.
                let pending = Set(changes.map(\.id))
                let previous = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
                lifetime.finish(commit: true)
                fields = details.configurations.map { entry in
                    if pending.contains(entry.name), let field = previous[entry.name] { return field }
                    return Self.field(entry)
                }
                fields += previous.values.filter { field in pending.contains(field.id) && !details.configurations.contains(where: { $0.name == field.id }) }
                fields.sort { $0.id < $1.id }
                if !needsReload { error = nil }
            } else {
                try accept(details)
                error = nil
            }
        } catch {
            self.error = error.localizedDescription
            needsReload = true
        }
    }

    func discard() {
        guard !isBusy else { return }
        lifetime.finish(commit: false)
        fields = latest?.configurations.map(Self.field).sorted { $0.id < $1.id } ?? []
        didSave = false
        error = nil
        // Keep the reload requirement after an uncertain write.
    }

    func revert(_ id: String) {
        guard !isBusy, let index = fields.firstIndex(where: { $0.id == id }) else { return }
        lifetime.finish(commit: false)
        if let latest {
            if let entry = latest.configurations.first(where: { $0.name == id }) { fields[index] = Self.field(entry) }
            else { fields.remove(at: index) }
        } else {
            fields[index] = Self.field(fields[index].original)
        }
        didSave = false
        error = nil
    }

    private static func field(_ entry: WorkspaceKafkaTopicConfiguration) -> Field {
        Field(original: entry, value: entry.value ?? "", inheritsDefault: entry.isDefault)
    }

    private func accept(_ details: WorkspaceKafkaTopicDetails) throws {
        guard details.configurationError == nil else { throw WorkspaceKafkaTopicConfigurationError.unavailable }
        lifetime.finish(commit: false)
        latest = details
        fields = details.configurations.map(Self.field).sorted { $0.id < $1.id }
        needsReload = false
    }
}
