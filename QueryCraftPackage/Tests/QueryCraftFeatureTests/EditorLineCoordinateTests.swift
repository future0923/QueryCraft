import Foundation
@testable import CodeEditTextView
import Testing

struct EditorLineCoordinateTests {
    private struct Line: Identifiable { let id = UUID() }

    @Test
    func deletingLeadingLinesKeepsTheDocumentOriginReachable() throws {
        // Fractional font metrics exposed a positive remainder at the origin
        // after deleting 18 of 36 lines. A y=0 lookup then returned no line.
        let lineHeight: CGFloat = 18.37265625
        for count in 4...100 {
            let storage = TextLineStorage<Line>()
            storage.build(from: (0..<count).map { _ in
                .init(data: Line(), length: 10, height: lineHeight)
            }, estimatedLineHeight: lineHeight)
            for index in (0..<count / 2).reversed() {
                storage.delete(lineAt: index * 10)
                let first = try #require(storage.getLine(atIndex: 0))
                #expect(first.yPos == 0)
                #expect(storage.getLine(atOffset: 0)?.yPos == 0)
                #expect(storage.getLine(atPosition: 0)?.data.id == first.data.id)
                for lineIndex in 0..<storage.count {
                    let line = try #require(storage.getLine(atIndex: lineIndex))
                    #expect(storage.getLine(atOffset: line.range.location)?.yPos == line.yPos)
                    #expect(storage.getLine(atPosition: line.yPos + line.height / 2)?.data.id == line.data.id)
                }
            }
        }
    }
}
