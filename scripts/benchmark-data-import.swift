import Foundation
import Darwin

// Localization only: parsing and snapshot storage below are unmodified production sources.
struct AppCopy {
    static let current = AppCopy()
    func text(_ zh: String, _ en: String) -> String { en }
}

@main struct Benchmark {
    static func main() async throws {
        let count = Int(CommandLine.arguments.dropFirst().first ?? "28311")!
        let width = Int(CommandLine.arguments.dropFirst(2).first ?? "78")!
        let directory = FileManager.default.temporaryDirectory.appending(path: "qc-import-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
        let url = external ?? directory.appending(path: "wide.sql")
        if external == nil {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        let names = (0..<width).map { "`column_\($0)`" }.joined(separator: ",")
        let value = "'中文🙂 O''Reilly \\n 1234567890123456789.123456789'"
        let tuple = "(" + (0..<width).map { $0 == 0 ? "9007199254740993" : $0 % 3 == 0 ? "NULL" : $0 % 3 == 1 ? value : "-1234567890.123456789e-10" }.joined(separator: ",") + ")"
        var remaining = count
        while remaining > 0 {
            let size = min(remaining, 1000)
            try autoreleasepool {
            let statement = "INSERT INTO source (\(names)) VALUES\n" + Array(repeating: tuple, count: size).joined(separator: ",\n") + ";\n"
            try writer.write(contentsOf: Data(statement.utf8))
            }
            remaining -= size
        }
        try writer.close()
        }
        let bytes = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize!
        var options = WorkspaceDataImportOptions(); options.format = .detect(url)
        if options.format == .json { options.firstDataRow = 1; options.headerRow = 0 }
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        let begin = ContinuousClock.now
        let file = try await WorkspaceDataImportReader().read(url: url, options: options)
        let parse = begin.duration(to: .now)
        guard file.rowCount == count, file.columns.count == width,
              try file.readRows(in: count-1..<count)[0][0] == "9007199254740993" else { fatalError("Lost data") }
        let scanStart = ContinuousClock.now
        var visited = 0
        for start in stride(from: 0, to: file.rowCount, by: 500) {
            visited += try file.readRows(in: start..<min(start+500, file.rowCount)).count
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let output: [String: Any] = ["rows": visited, "columns": width, "inputMiB": Double(bytes)/1048576,
            "generationPeakRSSMiB": Double(before.ru_maxrss)/1048576,
            "parseSeconds": seconds(parse), "batchReadSeconds": seconds(scanStart.duration(to: .now)),
            "peakRSSMiB": Double(usage.ru_maxrss)/1048576, "diskBacked": file.isDiskBacked,
            "previewRows": file.previewRows.count, "format": url.pathExtension]
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds)/1e18
    }
}
