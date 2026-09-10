import Foundation

actor RedisValueFormatter {
    func formattedJSON(from source: String) -> String? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              ),
              object is [Any] || object is [String: Any]
        else { return nil }
        return prettyPrintedJSONPreservingLexemes(source)
    }

    private func prettyPrintedJSONPreservingLexemes(
        _ source: String
    ) -> String {
        let scalars = Array(source.unicodeScalars)
        var output = ""
        var indentation = 0
        var isInsideString = false
        var isEscaped = false
        var index = 0

        func nextNonWhitespace(after position: Int) -> Unicode.Scalar? {
            var cursor = position + 1
            while cursor < scalars.count {
                let scalar = scalars[cursor]
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    return scalar
                }
                cursor += 1
            }
            return nil
        }

        func appendIndentation() {
            output.append(String(repeating: "  ", count: indentation))
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if isInsideString {
                output.unicodeScalars.append(scalar)
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if scalar == "\"" {
                isInsideString = true
                output.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                // Whitespace outside strings is presentation only.
            } else if scalar == "{" || scalar == "[" {
                output.unicodeScalars.append(scalar)
                let closes: Unicode.Scalar = scalar == "{" ? "}" : "]"
                if nextNonWhitespace(after: index) != closes {
                    indentation += 1
                    output.append("\n")
                    appendIndentation()
                }
            } else if scalar == "}" || scalar == "]" {
                let opensEmpty = index > 0 && {
                    var cursor = index - 1
                    while cursor >= 0 {
                        let candidate = scalars[cursor]
                        if CharacterSet.whitespacesAndNewlines.contains(candidate) {
                            if cursor == 0 { break }
                            cursor -= 1
                            continue
                        }
                        return candidate == "{" || candidate == "["
                    }
                    return false
                }()
                if !opensEmpty {
                    indentation = max(0, indentation - 1)
                    output.append("\n")
                    appendIndentation()
                }
                output.unicodeScalars.append(scalar)
            } else if scalar == "," {
                output.unicodeScalars.append(scalar)
                output.append("\n")
                appendIndentation()
            } else if scalar == ":" {
                output.append(": ")
            } else {
                output.unicodeScalars.append(scalar)
            }
            index += 1
        }
        return output
    }
}
