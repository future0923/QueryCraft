import AppKit
import CQueryCraftSSHTerminalRendererAPI
import SwiftTerm
import Testing
@testable import QueryCraftSSHTerminalRenderer

@MainActor @Suite(.serialized) struct TerminalInteractionTests {
    @MainActor private final class InputRecorder { var bytes: [UInt8] = [] }
    @MainActor private struct Fixture {
        let handle: UnsafeMutableRawPointer
        let view: InteractiveTerminalView
        let recorder: InputRecorder
        init() throws {
            NSApplication.shared.setActivationPolicy(.prohibited)
            recorder = InputRecorder()
            var callbacks = qc_terminal_callbacks()
            callbacks.size = UInt32(MemoryLayout<qc_terminal_callbacks>.size)
            callbacks.input = { context, bytes, count in
                guard let context, let bytes else { return }
                MainActor.assumeIsolated {
                    Unmanaged<InputRecorder>.fromOpaque(context).takeUnretainedValue().bytes.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
                }
            }
            callbacks.resize = { _, _, _ in }; callbacks.title = { _, _, _ in }
            handle = try #require(rendererCreate(&callbacks, Unmanaged.passUnretained(recorder).toOpaque()))
            let pointer = try #require(rendererView(handle))
            view = try #require(Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? InteractiveTerminalView)
        }
        func feed(_ text: String) { view.applyOutput(Array(text.utf8)[...]) }
        func close() { view.flushWheel(); rendererDestroy(handle) }
        var top: String {
            let terminal = view.getTerminal()
            return terminal.getLine(row: 0)?.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) }) ?? ""
        }
        func wheel(_ delta: Double, precise: Bool = false, modifiers: NSEvent.ModifierFlags = [], timestamp: Double = 1) {
            view.enqueueWheel(delta: delta, precise: precise, point: NSPoint(x: 20, y: 100), modifiers: modifiers, timestamp: timestamp)
        }
    }

    @Test func readingHistoryStaysInPlaceThroughOutputAndRingBufferTrimming() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.feed((0..<6000).map { "ROW_\($0)\r\n" }.joined())
        fixture.view.scroll(toPosition: 0.5)
        let visible = fixture.top
        #expect(!visible.isEmpty)
        fixture.feed((6000..<6100).map { "ROW_\($0)\r\n" }.joined())
        #expect(fixture.top == visible)
        fixture.view.scroll(toPosition: 1)
        fixture.feed("TAIL_MARKER\r\n")
        #expect(fixture.view.scrollPosition == 1)
        let terminal = fixture.view.getTerminal()
        #expect((0..<terminal.rows).contains { terminal.getLine(row: $0)?.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) }).contains("TAIL_MARKER") == true })
    }

    @Test func trackpadAccumulatesFractionsAndBatchesViewportUpdates() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.feed((0..<300).map { "ROW_\($0)\r\n" }.joined())
        let terminal = fixture.view.getTerminal()
        let original = terminal.getTopVisibleRow()
        let height = fixture.view.getOptimalFrameSize().height / CGFloat(terminal.rows)
        for index in 0..<4 { fixture.wheel(Double(height) / 4, precise: true, timestamp: 1 + Double(index) / 100) }
        #expect(terminal.getTopVisibleRow() == original)
        fixture.view.flushWheel()
        #expect(terminal.getTopVisibleRow() == original - 1)
        let scroller = try #require(fixture.view.subviews.compactMap { $0 as? NSScroller }.first)
        #expect(abs(scroller.doubleValue - fixture.view.scrollPosition) < 0.00001)
        fixture.wheel(-1, timestamp: 1.1); fixture.view.flushWheel()
        #expect(terminal.getTopVisibleRow() == original)
    }

    @Test func mouseAwareApplicationReceivesWheelReportsAtClampedCoordinates() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.feed("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        fixture.recorder.bytes.removeAll()
        fixture.wheel(1); fixture.view.flushWheel()
        let reports = String(decoding: fixture.recorder.bytes, as: UTF8.self)
        #expect(reports.components(separatedBy: "\u{1b}[<64;").count == 4)
        #expect(!reports.contains("\u{1b}[A"))
        fixture.recorder.bytes.removeAll()
        fixture.view.enqueueWheel(delta: -1, precise: false, point: NSPoint(x: -100, y: 10000), modifiers: [.control], timestamp: 1.1)
        fixture.view.flushWheel()
        #expect(String(decoding: fixture.recorder.bytes, as: UTF8.self).contains("\u{1b}[<81;1;1M"))
        fixture.recorder.bytes.removeAll()
        fixture.wheel(1, modifiers: [.shift], timestamp: 1.2); fixture.view.flushWheel()
        #expect(fixture.recorder.bytes.isEmpty)
    }

    @Test func alternateScreenFallbackUsesCursorModeAndCannotLeakQueuedInputAfterExit() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.feed("\u{1b}[?1049h\u{1b}[?1h")
        fixture.recorder.bytes.removeAll()
        fixture.wheel(-1); fixture.view.flushWheel()
        #expect(String(decoding: fixture.recorder.bytes, as: UTF8.self) == String(repeating: "\u{1b}OB", count: 3))
        fixture.recorder.bytes.removeAll()
        fixture.wheel(1, timestamp: 1.1)
        fixture.feed("\u{1b}[?1049l\u{1b}[?1l")
        fixture.view.flushWheel()
        #expect(fixture.recorder.bytes.isEmpty)
    }
}
