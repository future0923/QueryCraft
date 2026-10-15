import Foundation

enum WorkspaceDelimitedImporter {
    static func read(_ text: String, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        try read(WorkspaceDataImportByteReader(data: Data(text.utf8)), options: options)
    }
    static func read(handle: FileHandle, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        try read(WorkspaceDataImportByteReader(handle: handle), options: options)
    }
    private static func read(_ input: WorkspaceDataImportByteReader, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        let separator = options.format == .tsv ? "\t" : options.delimiter
        guard separator.count == 1, let character = separator.first, character != "\"", !character.isNewline else {
            throw WorkspaceDataImportError.invalid("分隔符必须是单个字符，且不能是引号或换行。", "Use one delimiter character other than a quote or newline.")
        }
        let delimiter = Array(separator.utf8)
        let table = try WorkspaceDataImportTableBuilder(options: options)
        var input = input
        try input.skipBOM()
        var row: [String?] = [], field = Data()
        var quoted = false, inQuotes = false, closedQuote = false, atStart = true, started = false
        func appendField() throws {
            guard let decoded = String(data: field, encoding: .utf8) else {
                throw WorkspaceDataImportError.invalid("文件包含无效 UTF-8 文本。", "The file contains invalid UTF-8 text.")
            }
            let value = options.trimsWhitespace ? decoded.trimmingCharacters(in: .whitespacesAndNewlines) : decoded
            let null = table.nextRecordNumber != options.headerRow && !quoted && !options.nullToken.isEmpty && value == options.nullToken
            row.append(null ? nil : value)
            field.removeAll(keepingCapacity: field.count < 1_048_576)
            quoted = false; closedQuote = false; atStart = true
        }
        while let byte = try input.peek() {
            try autoreleasepool {
                if inQuotes {
                    if byte == 34 {
                        input.advance()
                        if try input.peek() == 34 { field.append(34); input.advance() }
                        else { inQuotes = false; closedQuote = true }
                    } else {
                        field.append(input.run(until: { $0 == 34 }))
                    }
                    return
                }
                if byte == delimiter[0] {
                    var matches = true
                    for offset in delimiter.indices where try input.peek(offset) != delimiter[offset] { matches = false; break }
                    if matches { try appendField(); input.advance(delimiter.count); started = true; return }
                }
                var newline = 0
                if byte == 10 { newline = 1 }
                if byte == 13 { newline = try input.peek(1) == 10 ? 2 : 1 }
                if byte == 0xc2, try input.peek(1) == 0x85 { newline = 2 }
                if byte == 0xe2, try input.peek(1) == 0x80, let third = try input.peek(2), third == 0xa8 || third == 0xa9 { newline = 3 }
                if newline > 0 {
                    try appendField(); try table.append(row); row = []; started = false
                    input.advance(newline); return
                }
                if byte == 34 && atStart {
                    inQuotes = true; quoted = true; atStart = false; started = true; input.advance(); return
                }
                guard !closedQuote && byte != 34 else {
                    throw WorkspaceDataImportError.invalid("第 \(table.nextRecordNumber) 行的引号格式无效。", "Invalid quoting at record \(table.nextRecordNumber).")
                }
                // Copy ordinary ASCII/UTF-8 runs without per-character String allocations.
                let run = input.run(until: { $0 == delimiter[0] || $0 == 34 || $0 == 10 || $0 == 13 || $0 == 0xc2 || $0 == 0xe2 })
                if run.isEmpty { field.append(byte); input.advance() } else { field.append(run) }
                atStart = false; started = true
            }
        }
        guard !inQuotes else { throw WorkspaceDataImportError.invalid("文件包含未闭合的引号。", "The file contains an unterminated quote.") }
        if started || !row.isEmpty { try appendField(); try table.append(row) }
        return try table.finish()
    }
}
