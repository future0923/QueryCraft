import Foundation
import Observation

@MainActor @Observable
final class WorkspaceKafkaProducerModel {
    struct Header: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
        var usesNullValue = false
        var isBase64 = false
    }
    enum Format: String { case json, text, base64 }
    let topic: String
    let source: WorkspaceKafkaMessageReference?
    var partition = ""
    var usesNullKey = true
    var key = ""
    var keyIsBase64 = false
    var value = "{}"
    var format = Format.json
    var isJSON: Bool {
        get { format == .json }
        set { format = newValue ? .json : .text }
    }
    var usesNullValue = false
    var headers: [Header] = []
    private(set) var isLoadingSource = false
    private(set) var hasLoadedSource = false
    var needsSource: Bool { source != nil && !hasLoadedSource }
    private(set) var isSending = false
    private(set) var receipt: WorkspaceKafkaProduceReceipt?
    private(set) var error: String?

    init(topic: String, source: WorkspaceKafkaMessageReference? = nil) {
        self.topic = topic
        self.source = source
        if let source { partition = String(source.partition); value = ""; format = .text }
    }

    func loadSource(using load: (WorkspaceKafkaMessageReference) async throws -> WorkspaceKafkaMessagePayload) async {
        guard let source, needsSource, !isLoadingSource else { return }
        isLoadingSource = true
        error = nil
        defer { isLoadingSource = false }
        do {
            let payload = try await load(source)
            try Task.checkCancellation()
            usesNullKey = payload.key == nil
            keyIsBase64 = payload.key.map { String(data: $0, encoding: .utf8) == nil } ?? false
            key = Self.editableText(payload.key)
            usesNullValue = payload.value == nil
            value = Self.editableText(payload.value)
            if let bytes = payload.value, String(data: bytes, encoding: .utf8) == nil {
                format = .base64
            } else {
                // Preserve whitespace, escaped strings and large numeric lexemes verbatim.
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                isJSON = (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))
                    && (try? JSONSerialization.jsonObject(with: Data(value.utf8))) != nil
            }
            headers = payload.headers.map {
                Header(name: $0.name, value: Self.editableText($0.value), usesNullValue: $0.value == nil,
                       isBase64: $0.value.map { String(data: $0, encoding: .utf8) == nil } ?? false)
            }
            hasLoadedSource = true
        } catch is CancellationError {
            // Closing the draft cancels its read; no message is sent.
        } catch { self.error = error.localizedDescription }
    }

    private static func editableText(_ bytes: Data?) -> String {
        guard let bytes else { return "" }
        return String(data: bytes, encoding: .utf8) ?? bytes.base64EncodedString()
    }

    private static func bytes(_ text: String, base64: Bool) throws -> Data {
        guard base64 else { return Data(text.utf8) }
        guard let bytes = Data(base64Encoded: text) else { throw WorkspaceKafkaMessageCopyError.invalidBase64 }
        return bytes
    }

    func removeHeader(id: Header.ID) {
        guard !isSending else { return }
        headers.removeAll { $0.id == id }
    }

    func updateHeader<Value>(id: Header.ID, field: WritableKeyPath<Header, Value>, value: Value) {
        guard !isSending, let index = headers.firstIndex(where: { $0.id == id }) else { return }
        headers[index][keyPath: field] = value
    }

    func request() throws -> WorkspaceKafkaProduceRequest {
        guard !needsSource else { throw WorkspaceKafkaMessageCopyError.unavailable }
        let text = partition.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Int32(text)
        guard text.isEmpty || (parsed != nil && parsed! >= 0) else { throw WorkspaceKafkaProduceError.invalidPartition }
        if isJSON && !usesNullValue { _ = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) }
        let request = WorkspaceKafkaProduceRequest(topic: topic, partition: parsed,
            key: usesNullKey ? nil : try Self.bytes(key, base64: keyIsBase64),
            value: usesNullValue ? Data() : try Self.bytes(value, base64: format == .base64),
            headers: try headers.map { .init(name: $0.name, value: $0.usesNullValue ? nil : try Self.bytes($0.value, base64: $0.isBase64)) },
            isNullValue: usesNullValue)
        try request.validate()
        return request
    }

    var validationMessage: String? {
        do { _ = try request(); return nil } catch { return error.localizedDescription }
    }

    func formatJSON() {
        do {
            let object = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
            value = String(decoding: try JSONSerialization.data(withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func send(using produce: (WorkspaceKafkaProduceRequest) async throws -> WorkspaceKafkaProduceReceipt) async {
        guard !isSending else { return }
        do {
            let request = try request()
            isSending = true
            error = nil
            receipt = nil
            defer { isSending = false }
            receipt = try await produce(request)
        } catch { self.error = error.localizedDescription }
    }
}
