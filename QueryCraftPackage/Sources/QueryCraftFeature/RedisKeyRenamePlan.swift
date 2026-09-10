struct RedisKeyRenamePlan: Equatable, Sendable {
    let reference: RedisKeyReference
    let newName: String

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
