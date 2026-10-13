import Foundation
import Testing

@testable import QueryCraftFeature

struct SQLSnippetTests {
    @Test
    func parsesPlaceholdersIntoInsertionTextAndRanges() {
        let template = SQLSnippetTemplate(
            content: "SELECT *\nFROM ${table}\nWHERE ${condition};"
        )

        #expect(
            template.insertionText == "SELECT *\nFROM table\nWHERE condition;"
        )
        #expect(
            template.placeholderRanges == [
                SQLSourceRange(location: 14, length: 5),
                SQLSourceRange(location: 26, length: 9),
            ]
        )
        for (range, name) in zip(
            template.placeholderRanges,
            ["table", "condition"]
        ) {
            #expect(
                (template.insertionText as NSString)
                    .substring(with: range.nsRange) == name
            )
        }
    }

    @Test
    func keepsContentsWithoutPlaceholdersUntouched() {
        let template = SQLSnippetTemplate(content: "SELECT 1;\nSELECT 2;")

        #expect(template.insertionText == "SELECT 1;\nSELECT 2;")
        #expect(template.placeholderRanges.isEmpty)
    }

    @Test(arguments: [
        "SELECT ${",
        "SELECT ${}",
        "SELECT ${a$b}",
        "SELECT ${a{b}",
        "SELECT ${a\nb}",
        "SELECT $ {table}",
    ])
    func keepsMalformedPlaceholdersLiteral(_ content: String) {
        let template = SQLSnippetTemplate(content: content)

        #expect(template.insertionText == content)
        #expect(template.placeholderRanges.isEmpty)
    }

    @Test
    func supportsAdjacentAndRepeatedPlaceholders() {
        let template = SQLSnippetTemplate(content: "${a}${b} ${a}")

        #expect(template.insertionText == "ab a")
        #expect(
            template.placeholderRanges == [
                SQLSourceRange(location: 0, length: 1),
                SQLSourceRange(location: 1, length: 1),
                SQLSourceRange(location: 3, length: 1),
            ]
        )
    }

    @Test
    func tracksUTF16OffsetsForMultibyteNames() {
        let template = SQLSnippetTemplate(
            content: "SELECT '😀' FROM ${表格}"
        )

        #expect(template.insertionText == "SELECT '😀' FROM 表格")
        #expect(template.placeholderRanges == [
            SQLSourceRange(location: 17, length: 2),
        ])
    }

    @Test
    func previewCollapsesWhitespaceInTheInsertionText() {
        let template = SQLSnippetTemplate(
            content: "SELECT *\nFROM ${table}\nLIMIT 100;"
        )

        #expect(
            template.previewText == "SELECT * FROM ${table} LIMIT 100;"
        )
    }

    @Test
    func previewTruncatesLongContentsWithAnEllipsis() {
        let exact = SQLSnippetTemplate(
            content: String(repeating: "x", count: 120)
        )
        let long = SQLSnippetTemplate(
            content: String(repeating: "x", count: 200)
        )

        #expect(exact.previewText == String(repeating: "x", count: 120))
        #expect(long.previewText == String(repeating: "x", count: 120) + "…")
    }

    @Test
    func completionSourceCarriesTriggerAndParsedTemplate() {
        let snippet = SQLSnippet(
            name: "select *",
            trigger: "sel",
            content: "SELECT *\nFROM ${table}\nLIMIT 100;"
        )
        let source = SQLSnippetCompletionSource(snippet: snippet)

        #expect(source.name == "select *")
        #expect(source.trigger == "sel")
        #expect(source.insertionText == "SELECT *\nFROM table\nLIMIT 100;")
        #expect(
            source.previewText == "SELECT * FROM ${table} LIMIT 100;"
        )
        #expect(source.placeholderRanges == [
            SQLSourceRange(location: 14, length: 5),
        ])
    }
}
