#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

actor RedisValueFormatter {
    func formattedJSON(from source: String, maximumOutputBytes: Int? = nil) -> String? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              ),
              object is [Any] || object is [String: Any]
        else { return nil }
        return prettyPrintedJSONPreservingLexemes(source, maximumOutputBytes: maximumOutputBytes)
    }

    private func prettyPrintedJSONPreservingLexemes(
        _ source: String,
        maximumOutputBytes: Int?
    ) -> String? {
        let scalars = source.unicodeScalars
        var output = ""
        var indentation = 0
        var isInsideString = false
        var isEscaped = false
        var index = scalars.startIndex

        func nextNonWhitespace(after position: String.UnicodeScalarView.Index) -> Unicode.Scalar? {
            var cursor = scalars.index(after: position)
            while cursor < scalars.endIndex {
                let scalar = scalars[cursor]
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    return scalar
                }
                cursor = scalars.index(after: cursor)
            }
            return nil
        }

        func appendIndentation() {
            output.append(String(repeating: "  ", count: indentation))
        }

        while index < scalars.endIndex {
            if let maximumOutputBytes, output.utf8.count > maximumOutputBytes { return nil }
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
                index = scalars.index(after: index)
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
                let opensEmpty = index > scalars.startIndex && {
                    var cursor = scalars.index(before: index)
                    while cursor >= scalars.startIndex {
                        let candidate = scalars[cursor]
                        if CharacterSet.whitespacesAndNewlines.contains(candidate) {
                            if cursor == scalars.startIndex { break }
                            cursor = scalars.index(before: cursor)
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
            index = scalars.index(after: index)
        }
        if let maximumOutputBytes, output.utf8.count > maximumOutputBytes { return nil }
        return output
    }
}
