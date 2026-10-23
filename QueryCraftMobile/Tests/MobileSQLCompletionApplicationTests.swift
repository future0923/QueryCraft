import XCTest
@testable import QueryCraftMobileProof

final class MobileSQLCompletionApplicationTests: XCTestCase {
    func testTokenSeparatorReusesWhitespaceAndPreservesUTF16OffsetsAndDesktopDefault() {
        let item = candidate("SELECT", at: 6, replacing: 3)
        let original = SQLCompletionApplication.insertion(for: item, in: "-- 😀\nSEL")
        XCTAssertEqual(original.text, "SELECT"); XCTAssertEqual(original.selection.location, 12)
        XCTAssertFalse(original.beginsNextToken)
        for suffix in ["", " FROM sample", "\tFROM sample"] {
            let edit = SQLCompletionApplication.insertion(for: item, in: "-- 😀\nSEL" + suffix, separateToken: true)
            XCTAssertEqual(edit.text, suffix.isEmpty ? "SELECT " : "SELECT")
            XCTAssertEqual(edit.selection, .init(location: 13, length: 0)); XCTAssertTrue(edit.beginsNextToken)
        }
    }

    func testSeparatorNeverSplitsPunctuationIdentifiersOrLines() {
        for suffix in [".", ",", ")", ";", "(", "\nFROM", "tail", "😀"] {
            let item = candidate("sample", kind: .table)
            let edit = SQLCompletionApplication.insertion(for: item, in: "sam" + suffix, separateToken: true)
            XCTAssertEqual(edit.text, "sample"); XCTAssertEqual(edit.selection.location, 6)
            XCTAssertFalse(edit.beginsNextToken, suffix)
        }
        for kind in [SQLCompletionItem.Kind.keyword, .table, .view, .column, .queryOutput] {
            XCTAssertTrue(SQLCompletionApplication.insertion(for: candidate("`用户`", kind: kind), in: "sam", separateToken: true).beginsNextToken)
        }
    }

    func testFunctionsDatabasesAndPlaceholdersRetainExactSharedSelection() {
        let items = [candidate("COUNT()", kind: .function, cursorOffset: -1), candidate("proof", kind: .database),
            candidate("SELECT value", kind: .snippet, selections: [.init(location: 7, length: 5)]), candidate("FROM ")]
        for item in items {
            let edit = SQLCompletionApplication.insertion(for: item, in: "sam", separateToken: true)
            XCTAssertEqual(edit.text, item.insertionText)
            XCTAssertEqual(edit.selection, SQLCompletionApplication.selection(after: item)); XCTAssertFalse(edit.beginsNextToken)
        }
    }

    private func candidate(_ text: String, kind: SQLCompletionItem.Kind = .keyword, at: Int = 0, replacing: Int = 3,
                           cursorOffset: Int = 0, selections: [SQLSourceRange] = []) -> SQLCompletionItem {
        .init(label: text, insertionText: text, detail: "", kind: kind, replacementRange: .init(location: at, length: replacing),
              sourceRevision: .init(1), cursorOffset: cursorOffset, selectionRanges: selections)
    }
}
