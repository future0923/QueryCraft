import Foundation

/// Keep ordinary snippets readable. Encode multiline/control source into one
/// shell command; bounded continued lines also support scripts larger than a
/// canonical terminal input line. No command is accepted until the final Return.
enum SSHScriptTerminalInput {
    static func command(_ source: String) throws -> String {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= 65_536, !source.contains("\0") else { throw MCPFailure("Invalid saved script.") }
        let line = source.trimmingCharacters(in: .newlines)
        if line.utf8.count <= 200 && !line.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return line }
        var arguments: [String] = [], chunk = "", quotedBytes = 2
        for scalar in source.unicodeScalars {
            let token: String
            switch scalar.value {
            case 92: token = "\\\\"
            case 10: token = "\\n"
            case 13: token = "\\r"
            case 9: token = "\\t"
            case 1..<32, 127: token = String(format: "\\0%03o", scalar.value)
            default: token = String(scalar)
            }
            let cost = token.utf8.count + (scalar.value == 39 ? 4 : 0)
            if quotedBytes + cost > 128 {
                arguments.append(SSHTaskCommand.shellQuote(chunk)); chunk = ""; quotedBytes = 2
            }
            chunk += token; quotedBytes += cost
        }
        if !chunk.isEmpty { arguments.append(SSHTaskCommand.shellQuote(chunk)) }
        // Keep trailing source newlines via trailing whitespace, without another command.
        arguments.append("'\\n '")
        let separator = arguments.reduce(32) { $0 + $1.utf8.count + 1 } <= 200 ? " " : " \\\n"
        return "eval \"$(printf '%b' " + arguments.joined(separator: separator) + ")\""
    }
}
