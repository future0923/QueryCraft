import Foundation

struct SQLSnippet: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var trigger: String
    var content: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        trigger: String,
        content: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.content = content
        self.isEnabled = isEnabled
    }
}

/// `content` 中的 `${名称}` 为占位符：插入时替换为其名称本身，
/// 并把第一个占位符整词选中，便于直接输入替换。
struct SQLSnippetTemplate: Equatable, Sendable {
    let content: String
    let insertionText: String
    let placeholderRanges: [SQLSourceRange]

    init(content: String) {
        self.content = content
        let characters = Array(content)
        var insertionText = ""
        var insertionLength = 0
        var placeholderRanges: [SQLSourceRange] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "$",
                index + 1 < characters.count,
                characters[index + 1] == "{",
                let closingIndex = characters[(index + 2)...].firstIndex(of: "}")
            {
                let name = String(characters[(index + 2)..<closingIndex])
                if Self.isValidPlaceholderName(name) {
                    let length = (name as NSString).length
                    placeholderRanges.append(
                        SQLSourceRange(location: insertionLength, length: length)
                    )
                    insertionText += name
                    insertionLength += length
                    index = closingIndex + 1
                    continue
                }
            }
            let character = characters[index]
            insertionText.append(character)
            insertionLength += String(character).utf16.count
            index += 1
        }
        self.insertionText = insertionText
        self.placeholderRanges = placeholderRanges
    }

    /// 展示用文本：保留 `${名称}` 占位符写法，仅折叠空白并截断。
    var previewText: String {
        let collapsed = content
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > Self.previewLimit else { return collapsed }
        return String(collapsed.prefix(Self.previewLimit)) + "…"
    }

    private static let previewLimit = 120

    private static func isValidPlaceholderName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains(where: { $0 == "$" || $0 == "{" || $0 == "}" || $0.isNewline })
    }
}

struct SQLSnippetCompletionSource: Equatable, Sendable {
    let name: String
    let trigger: String
    let insertionText: String
    let previewText: String
    let placeholderRanges: [SQLSourceRange]

    init(snippet: SQLSnippet) {
        let template = SQLSnippetTemplate(content: snippet.content)
        name = snippet.name
        trigger = snippet.trigger
        insertionText = template.insertionText
        previewText = template.previewText
        placeholderRanges = template.placeholderRanges
    }
}
