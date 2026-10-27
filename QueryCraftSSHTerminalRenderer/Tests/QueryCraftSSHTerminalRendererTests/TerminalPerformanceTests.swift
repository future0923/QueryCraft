import AppKit
import CQueryCraftSSHTerminalRendererAPI
import SwiftTerm
import Testing
@testable import QueryCraftSSHTerminalRenderer

@MainActor @Suite(.serialized) struct TerminalPerformanceTests {
    @Test func outputAndHistoryBenchmark() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var callbacks = qc_terminal_callbacks()
        callbacks.size = UInt32(MemoryLayout<qc_terminal_callbacks>.size)
        callbacks.input = { _, _, _ in }; callbacks.resize = { _, _, _ in }; callbacks.title = { _, _, _ in }
        let handle = try #require(rendererCreate(&callbacks, nil))
        defer { rendererDestroy(handle) }
        let pointer = try #require(rendererView(handle))
        let view = try #require(Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? TerminalView)
        let bytes = Array((0..<20_000).map { "\u{1b}[32m\($0)\u{1b}[0m short log line 中文\r\n" }.joined().utf8)
        let clock = ContinuousClock(); let start = clock.now
        var longest = Duration.zero
        for offset in stride(from: 0, to: bytes.count, by: 4096) {
            let begin = clock.now
            bytes.withUnsafeBufferPointer { rendererFeed(handle, $0.baseAddress! + offset, min(4096, bytes.count - offset)) }
            longest = max(longest, begin.duration(to: clock.now))
        }
        let elapsed = start.duration(to: clock.now)
        let scrollStart = clock.now
        for index in 0..<120 { view.scroll(toPosition: Double(index % 100) / 100) }
        print("TERMINAL_BENCH bytes=\(bytes.count) elapsed=\(elapsed) max_4k=\(longest) scroll120=\(scrollStart.duration(to: clock.now))")
        view.scroll(toPosition: 1)
        let terminal = view.getTerminal()
        let tail = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) }) }.joined(separator: "\n")
        #expect(tail.contains("19999"))
    }
}
