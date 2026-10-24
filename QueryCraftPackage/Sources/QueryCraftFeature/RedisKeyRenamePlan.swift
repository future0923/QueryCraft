import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

struct RedisKeyRenamePlan: Equatable, Sendable {
    let reference: RedisKeyReference
    let newName: String

    static func make(reference: RedisKeyReference, proposedName: String) throws -> Self {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RedisKeyEditError.invalidKeyName }
        return .init(reference: reference, newName: name)
    }

    func result(for reply: RedisReplyValue) throws -> RedisKeyReference {
        guard case let .integer(value) = reply, value == 0 || value == 1 else {
            throw RedisWorkspaceError.invalidReply("RENAMENX")
        }
        guard value == 1 else { throw RedisKeyEditError.keyAlreadyExists(newName) }
        return .init(databaseIndex: reference.databaseIndex, name: newName, type: reference.type)
    }

    var command: RedisCommandInvocation {
        RedisCommandInvocation(
            source: "RENAMENX "
                + RedisCommandPreviewFormatter.escaped(reference.name)
                + " "
                + RedisCommandPreviewFormatter.escaped(newName),
            arguments: ["RENAMENX", reference.name, newName]
        )
    }
}
