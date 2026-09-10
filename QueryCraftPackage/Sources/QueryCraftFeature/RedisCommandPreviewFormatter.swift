import Foundation

enum RedisCommandPreviewFormatter {
    static func source(for invocation: RedisCommandInvocation) -> String {
        invocation.arguments.map(escaped).joined(separator: " ")
    }

    static func escaped(_ argument: String) -> String {
        guard !argument.isEmpty,
              argument.unicodeScalars.allSatisfy(isUnquotedScalar)
        else {
            return "\"\(escapedQuotedContent(argument))\""
        }
        return argument
    }

    private static func isUnquotedScalar(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && scalar != "\""
            && scalar != "\\"
            && !CharacterSet.controlCharacters.contains(scalar)
    }

    private static func escapedQuotedContent(_ argument: String) -> String {
        argument
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
