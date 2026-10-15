import CodeEditLanguages
import Foundation
import SwiftTreeSitter

enum SQLStructuralParserError: Error, Equatable {
    case languageUnavailable
    case parserSetupFailed
    case highlightQueryUnavailable
    case parseFailed
    case staleRevision
    case invalidEdit
}

actor SQLStructuralParser {
    private struct CachedStatement {
        let syntax: SQLSyntaxNodeSnapshot
        let kind: SQLStatementKind
        let scope: SQLQueryScopeSnapshot?
    }

    private struct CachedParse {
        let source: SQLSourceSnapshot
        let tree: Tree
        let snapshot: SQLParseSnapshot
        let recoveredHighlights: [SQLIndexHighlightRecovery.Correction]
        let statements: [UInt: CachedStatement]
    }

    private let parser: Parser
    private let highlightQuery: Query
    private var cachedParse: CachedParse?
    private var displayTreeCache: (revision: SQLSourceRevision, context: SQLHighlightContext, tree: Tree)?

    init() throws {
        guard let language = CodeLanguage.sql.language else {
            throw SQLStructuralParserError.languageUnavailable
        }
        let parser = Parser()
        do {
            try parser.setLanguage(language)
        } catch {
            throw SQLStructuralParserError.parserSetupFailed
        }
        guard let highlightQuery = TreeSitterModel.shared.query(for: .sql) else {
            throw SQLStructuralParserError.highlightQueryUnavailable
        }
        self.parser = parser
        // Error recovery on a large incremental tree can otherwise run indefinitely.
        parser.timeout = 10
        self.highlightQuery = highlightQuery
    }

    func parse(
        _ source: SQLSourceSnapshot,
        applying edit: SQLSourceEdit? = nil
    ) throws -> SQLParseSnapshot {
        let timing = ProcessInfo.processInfo.environment["QUERYCRAFT_EDITOR_PERFORMANCE"] == "1"
        var phase = ContinuousClock.now
        func mark(_ name: String) {
            if timing { print("SQL_PHASE \(name) \(phase.duration(to: .now))") }
            if timing { phase = .now }
        }
        try Task.checkCancellation()
        if let cachedParse, source.revision <= cachedParse.source.revision {
            throw SQLStructuralParserError.staleRevision
        }

        let parsedTree: MutableTree
        let changedRanges: [SQLSourceRange]
        let mode: SQLParseSnapshot.Mode
        if let edit,
           let cachedParse,
           edit.baseRevision == cachedParse.source.revision
        {
            let result = try parseIncrementally(
                source,
                edit: edit,
                cachedParse: cachedParse
            )
            parsedTree = result.tree
            changedRanges = result.changedRanges
            mode = result.mode
        } else {
            let tree = parser.parse(source.text)
            guard let tree else {
                parser.reset()
                throw SQLStructuralParserError.parseFailed
            }
            parsedTree = tree
            changedRanges = source.text.isEmpty
                ? []
                : [SQLSourceRange(location: 0, length: (source.text as NSString).length)]
            mode = .full
        }

        mark("tree")
        try Task.checkCancellation()
        guard let initialTree = parsedTree.copy(),
              let initialRootNode = initialTree.rootNode
        else {
            throw SQLStructuralParserError.parseFailed
        }
        var tree = initialTree
        let reusedStatements = mode == .incremental ? cachedParse?.statements ?? [:] : [:]
        var syntaxTree = Self.syntaxSnapshot(for: initialRootNode, reusing: reusedStatements)
        var snapshotChangedRanges = changedRanges
        var snapshotMode = mode
        if let recoverySource = Self.clauseRecoverySource(
            syntaxTree: syntaxTree,
            source: source.text as NSString
        ) {
            guard let recoveredMutableTree = parser.parse(recoverySource),
                  let recoveredTree = recoveredMutableTree.copy()
            else {
                parser.reset()
                throw SQLStructuralParserError.parseFailed
            }
            tree = recoveredTree
            if let recoveredRoot = tree.rootNode { syntaxTree = Self.syntaxSnapshot(for: recoveredRoot) }
            snapshotChangedRanges = source.text.isEmpty
                ? []
                : [SQLSourceRange(
                    location: 0,
                    length: (source.text as NSString).length
                )]
            snapshotMode = .full
        }
        guard let rootNode = tree.rootNode else {
            throw SQLStructuralParserError.parseFailed
        }
        let carriedRelationReferences: [SQLRelationReferenceSnapshot]
        if let edit, let cachedParse, snapshotMode == .incremental {
            carriedRelationReferences = Self.carriedRelationReferences(
                from: cachedParse.snapshot,
                previousSource: cachedParse.source.text,
                source: source.text,
                edit: edit
            )
        } else {
            carriedRelationReferences = []
        }
        mark("syntax")
        let snapshot = Self.makeSnapshot(
            source: source,
            rootNode: rootNode,
            syntaxTree: syntaxTree,
            reusedStatements: snapshotMode == .incremental ? reusedStatements : [:],
            changedRanges: snapshotChangedRanges,
            mode: snapshotMode,
            carriedRelationReferences: carriedRelationReferences
        )
        mark("snapshot")
        let syntaxByLocation = Dictionary(grouping: syntaxTree.children.filter { $0.type == "statement" }, by: \.range.location)
        let statementsByLocation = Dictionary(grouping: snapshot.statements, by: \.range.location)
        let scopesByLocation = Dictionary(grouping: snapshot.queryScopes, by: \.range.location)
        var statementCache: [UInt: CachedStatement] = [:]
        for node in Self.childNodes(of: rootNode) where node.nodeType == "statement" && !node.hasError {
            guard let syntax = syntaxByLocation[node.range.location]?.first,
                  let statement = statementsByLocation[node.range.location]?.first else { continue }
            statementCache[node.id] = .init(syntax: syntax, kind: statement.kind, scope: scopesByLocation[node.range.location]?.first)
        }
        let corrections = edit.flatMap { edit in
            cachedParse.flatMap { Self.incrementalRecovery(source: source.text, snapshot: snapshot, edit: edit, previous: $0) }
        } ?? (SQLLexicalHighlightRecovery.highlights(in: source.text) + SQLIndexHighlightRecovery.highlights(in: source.text))
        cachedParse = CachedParse(source: source, tree: tree, snapshot: snapshot,
                                  recoveredHighlights: corrections, statements: statementCache)
        mark("recovery")
        return snapshot
    }

    /// Re-scan only one complete, reliable statement when every other statement
    /// retains its boundary. Any lexical error or boundary change uses the full scan.
    private static func incrementalRecovery(source: String, snapshot: SQLParseSnapshot, edit: SQLSourceEdit,
                                            previous: CachedParse) -> [SQLIndexHighlightRecovery.Correction]? {
        guard edit.baseRevision == previous.source.revision,
              snapshot.isReliable, previous.snapshot.isReliable,
              snapshot.unreliableStatementRanges.isEmpty, previous.snapshot.unreliableStatementRanges.isEmpty,
              snapshot.statements.count == previous.snapshot.statements.count,
              let index = previous.snapshot.statements.firstIndex(where: {
                  $0.range.contains(edit.replacedRange) && edit.replacedRange.location < $0.range.upperBound
              }) else { return nil }
        let oldRange = previous.snapshot.statements[index].range
        let newRange = snapshot.statements[index].range
        let delta = edit.replacement.utf16.count - edit.replacedRange.length
        guard newRange.location == oldRange.location, newRange.length == oldRange.length + delta else { return nil }
        for offset in snapshot.statements.indices where offset != index {
            let expected = previous.snapshot.statements[offset].range.shiftedForReuse(by: offset > index ? delta : 0)
            guard snapshot.statements[offset].range == expected else { return nil }
        }
        // Recoveries must not straddle the statement boundaries being replaced.
        guard previous.recoveredHighlights.allSatisfy({
            let range = $0.highlight.range
            return range.upperBound <= oldRange.location || range.location >= oldRange.upperBound || oldRange.contains(range)
        }) else { return nil }
        var result = previous.recoveredHighlights.compactMap { correction -> SQLIndexHighlightRecovery.Correction? in
            let range = correction.highlight.range
            if oldRange.contains(range) { return nil }
            let shift = range.location >= oldRange.upperBound ? delta : 0
            return .init(highlight: .init(range: range.shiftedForReuse(by: shift), kind: correction.highlight.kind),
                         preservesExistingSyntax: correction.preservesExistingSyntax)
        }
        let fragment = (source as NSString).substring(with: newRange.nsRange)
        result += (SQLLexicalHighlightRecovery.highlights(in: fragment) + SQLIndexHighlightRecovery.highlights(in: fragment)).map {
            .init(highlight: .init(range: $0.highlight.range.shiftedForReuse(by: newRange.location), kind: $0.highlight.kind),
                  preservesExistingSyntax: $0.preservesExistingSyntax)
        }
        return result
    }

    private static func clauseRecoverySource(
        syntaxTree: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> String? {
        let clauseNames: Set<String> = [
            "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET",
            "JOIN", "LEFT", "RIGHT", "INNER", "CROSS", "ON", "UNION",
            "INTERSECT", "EXCEPT", "INTO",
        ]
        let recoveredSource = NSMutableString(string: source)
        var recoveredDotLocations: Set<Int> = []

        for invocation in syntaxTree.descendants(named: "invocation") {
            guard let reference = invocation
                .descendants(named: "object_reference")
                .first
            else {
                continue
            }
            let identifiers = reference
                .descendants(named: "identifier")
                .sorted { $0.range.location < $1.range.location }
            guard identifiers.count >= 2,
                  let clause = identifierText(
                    in: identifiers[identifiers.count - 1],
                    source: source
                  )?.uppercased(),
                  clauseNames.contains(clause)
            else {
                continue
            }
            let preceding = identifiers[identifiers.count - 2]
            let clauseIdentifier = identifiers[identifiers.count - 1]
            let gapRange = NSRange(
                location: preceding.range.upperBound,
                length: clauseIdentifier.range.location
                    - preceding.range.upperBound
            )
            guard gapRange.location >= 0,
                  gapRange.length > 1,
                  NSMaxRange(gapRange) <= source.length
            else {
                continue
            }
            let gap = source.substring(with: gapRange) as NSString
            let relativeDot = gap.range(
                of: ".",
                options: .backwards
            )
            guard relativeDot.location != NSNotFound else { continue }
            let dotLocation = gapRange.location + relativeDot.location
            let afterDotRange = NSRange(
                location: dotLocation + 1,
                length: clauseIdentifier.range.location - dotLocation - 1
            )
            guard afterDotRange.length > 0,
                  source.substring(with: afterDotRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            else {
                continue
            }
            recoveredDotLocations.insert(dotLocation)
        }

        guard !recoveredDotLocations.isEmpty else { return nil }
        for location in recoveredDotLocations {
            recoveredSource.replaceCharacters(
                in: NSRange(location: location, length: 1),
                with: " "
            )
        }
        return recoveredSource as String
    }

    func highlights(
        in requestedRange: SQLSourceRange,
        revision: SQLSourceRevision,
        context: SQLHighlightContext = .generic
    ) throws -> [SQLSyntaxHighlight] {
        try Task.checkCancellation()
        guard let cachedParse, cachedParse.source.revision == revision else {
            throw SQLStructuralParserError.staleRevision
        }

        let documentRange = NSRange(
            location: 0,
            length: (cachedParse.source.text as NSString).length
        )
        guard let includedRange = requestedRange.nsRange.intersection(documentRange),
              includedRange.length > 0
        else {
            return []
        }

        let displayTree: Tree
        if let cache = displayTreeCache, cache.revision == revision, cache.context == context {
            displayTree = cache.tree
        } else if let displaySource = context.displaySource(cachedParse.source.text) {
            let displayParser = Parser()
            guard let language = CodeLanguage.sql.language else { throw SQLStructuralParserError.languageUnavailable }
            try displayParser.setLanguage(language)
            displayParser.timeout = 10
            guard let tree = displayParser.parse(displaySource)?.copy() else { throw SQLStructuralParserError.parseFailed }
            displayTree = tree
            displayTreeCache = (revision, context, tree)
        } else {
            displayTree = cachedParse.tree
            displayTreeCache = (revision, context, displayTree)
        }
        guard let rootNode = displayTree.rootNode else { return [] }
        let cursor = highlightQuery.execute(node: rootNode, in: displayTree)
        cursor.setRange(includedRange)
        cursor.matchLimit = 256

        var highlightsByRange: [SQLSourceRange: SQLSyntaxHighlight] = [:]
        for match in cursor.resolve(with: .init(string: cachedParse.source.text)) {
            try Task.checkCancellation()
            for capture in match.captures {
                guard let kind = Self.syntaxKind(for: capture.name),
                      let intersection = capture.range.intersection(includedRange),
                      intersection.length > 0
                else {
                    continue
                }

                let range = SQLSourceRange(intersection)
                let candidate = SQLSyntaxHighlight(range: range, kind: kind)
                if let existing = highlightsByRange[range],
                   Self.syntaxPriority(existing.kind) >= Self.syntaxPriority(kind) {
                    continue
                }
                highlightsByRange[range] = candidate
            }
        }

        for highlight in Self.recoveredTransactionHighlights(
            statements: cachedParse.snapshot.statements,
            source: cachedParse.source.text,
            includedRange: includedRange
        ) {
            highlightsByRange = highlightsByRange.filter { range, _ in
                NSIntersectionRange(range.nsRange, highlight.range.nsRange).length == 0
            }
            highlightsByRange[highlight.range] = highlight
        }

        var protectedSyntax = IndexSet()
        for highlight in highlightsByRange.values {
            switch highlight.kind {
            case .keyword, .builtinType, .boolean, .comment, .string, .number, .parameter, .attribute:
                protectedSyntax.insert(integersIn: highlight.range.location..<highlight.range.upperBound)
            default: break
            }
        }
        let recovered = cachedParse.recoveredHighlights.compactMap { correction -> SQLSyntaxHighlight? in
            let highlight = correction.highlight
            guard let range = highlight.range.nsRange.intersection(includedRange), range.length > 0 else { return nil }
            if correction.preservesExistingSyntax,
               protectedSyntax.intersects(integersIn: range.location..<NSMaxRange(range)) { return nil }
            return SQLSyntaxHighlight(range: SQLSourceRange(range), kind: highlight.kind)
        }
        if !recovered.isEmpty {
            var replaced = IndexSet()
            for highlight in recovered { replaced.insert(integersIn: highlight.range.location..<highlight.range.upperBound) }
            highlightsByRange = highlightsByRange.filter { range, _ in
                !replaced.intersects(integersIn: range.location..<range.upperBound)
            }
            for highlight in recovered { highlightsByRange[highlight.range] = highlight }
        }

        return highlightsByRange.values.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
    }

    private static func recoveredTransactionHighlights(
        statements: [SQLStatement],
        source: String,
        includedRange: NSRange
    ) -> [SQLSyntaxHighlight] {
        let source = source as NSString
        return statements.flatMap { statement -> [SQLSyntaxHighlight] in
            switch statement.kind {
            case .transaction(.begin), .transaction(.commit),
                 .transaction(.rollback):
                break
            case .transaction(.savepoint):
                let statementText = source.substring(
                    with: statement.range.nsRange
                )
                let fullRange = NSRange(
                    location: 0,
                    length: (statementText as NSString).length
                )
                guard let expression = try? NSRegularExpression(
                    pattern: #"(?i)^\s*(SAVEPOINT|RELEASE\s+SAVEPOINT|ROLLBACK(?:\s+WORK)?\s+TO(?:\s+SAVEPOINT)?)\b"#
                ),
                      let match = expression.firstMatch(
                        in: statementText,
                        range: fullRange
                      ),
                      match.range(at: 1).location != NSNotFound
                else {
                    return []
                }
                let keywordRange = NSRange(
                    location: statement.range.location
                        + match.range(at: 1).location,
                    length: match.range(at: 1).length
                )
                guard let intersection = keywordRange.intersection(
                    includedRange
                ), intersection.length > 0 else {
                    return []
                }
                return [
                    SQLSyntaxHighlight(
                        range: SQLSourceRange(intersection),
                        kind: .keyword
                    )
                ]
            default:
                return []
            }

            let statementText = source.substring(with: statement.range.nsRange)
            var payload = statementText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if payload.hasSuffix(";") {
                payload.removeLast()
                payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !payload.isEmpty else { return [] }

            let offset = (statementText as NSString).range(of: payload).location
            let payloadRange = NSRange(
                location: statement.range.location + offset,
                length: (payload as NSString).length
            )
            guard let intersection = payloadRange.intersection(includedRange),
                  intersection.length > 0
            else {
                return []
            }
            return [
                SQLSyntaxHighlight(
                    range: SQLSourceRange(intersection),
                    kind: .keyword
                )
            ]
        }
    }

    private func parseIncrementally(
        _ source: SQLSourceSnapshot,
        edit: SQLSourceEdit,
        cachedParse: CachedParse
    ) throws -> (tree: MutableTree, changedRanges: [SQLSourceRange], mode: SQLParseSnapshot.Mode) {
        let previousText = cachedParse.source.text as NSString
        let range = edit.replacedRange.nsRange
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= previousText.length
        else {
            throw SQLStructuralParserError.invalidEdit
        }

        let expectedText = NSMutableString(string: cachedParse.source.text)
        expectedText.replaceCharacters(in: range, with: edit.replacement)
        guard expectedText.compare(source.text, options: .literal) == .orderedSame else {
            throw SQLStructuralParserError.invalidEdit
        }

        let newEndLocation = range.location + (edit.replacement as NSString).length
        let inputEdit = InputEdit(
            startByte: range.location * 2,
            oldEndByte: NSMaxRange(range) * 2,
            newEndByte: newEndLocation * 2,
            startPoint: Self.point(in: cachedParse.source.text, at: range.location),
            oldEndPoint: Self.point(in: cachedParse.source.text, at: NSMaxRange(range)),
            newEndPoint: Self.point(in: source.text, at: newEndLocation)
        )
        guard let editedTree = cachedParse.tree.edit(inputEdit) else {
            throw SQLStructuralParserError.parseFailed
        }
        parser.timeout = 2
        defer { parser.timeout = 10 }
        guard let parsedTree = parser.parse(tree: editedTree, string: source.text) else {
            // Discard the paused incremental state and retry the current source once.
            parser.reset()
            parser.timeout = 10
            guard let fullTree = parser.parse(source.text) else { parser.reset(); throw SQLStructuralParserError.parseFailed }
            return (fullTree, [.init(location: 0, length: source.text.utf16.count)], .full)
        }
        let changedRanges = editedTree.changedRanges(from: parsedTree).map { range in
            SQLSourceRange(range.bytes.range)
        }
        return (parsedTree, changedRanges, .incremental)
    }

    private static func makeSnapshot(
        source: SQLSourceSnapshot,
        rootNode: Node,
        syntaxTree: SQLSyntaxNodeSnapshot,
        reusedStatements: [UInt: CachedStatement],
        changedRanges: [SQLSourceRange],
        mode: SQLParseSnapshot.Mode,
        carriedRelationReferences: [SQLRelationReferenceSnapshot]
    ) -> SQLParseSnapshot {
        let nsSource = source.text as NSString
        var statements: [SQLStatement] = []
        var unreliableStatementRanges: [SQLSourceRange] = []
        var diagnostics: [SQLParseDiagnostic] = []
        var segmentNodes: [Node] = []

        let rootChildren = childNodes(of: rootNode)
        for child in rootChildren {
            if segmentNodes.isEmpty,
               let recoveredStatements = directTerminatedStatements(
                   inErrorNode: child,
                   source: nsSource
               )
            {
                statements.append(contentsOf: recoveredStatements)
                diagnostics.append(contentsOf: recoveredStatements.compactMap {
                    guard $0.kind == .unknown else { return nil }
                    return SQLParseDiagnostic(
                        range: $0.range,
                        reason: .unsupportedSyntax
                    )
                })
                continue
            }
            if isStatementTerminator(child, source: nsSource) {
                analyzeSegment(
                    nodes: segmentNodes,
                    terminatorEnd: child.range.location + child.range.length,
                    source: nsSource,
                    reusedStatements: reusedStatements,
                    statements: &statements,
                    unreliableStatementRanges: &unreliableStatementRanges,
                    diagnostics: &diagnostics
                )
                segmentNodes.removeAll(keepingCapacity: true)
            } else {
                segmentNodes.append(child)
            }
        }
        analyzeSegment(
            nodes: segmentNodes,
            terminatorEnd: nil,
            source: nsSource,
            reusedStatements: reusedStatements,
            statements: &statements,
            unreliableStatementRanges: &unreliableStatementRanges,
            diagnostics: &diagnostics
        )

        if !syntaxTree.descendants(named: "delimiter_directive").isEmpty {
            statements = []
            let documentRange = SQLSourceRange(
                location: 0,
                length: (source.text as NSString).length
            )
            unreliableStatementRanges = documentRange.length > 0
                ? [documentRange]
                : []
            diagnostics.append(
                SQLParseDiagnostic(
                    range: documentRange,
                    reason: .unsupportedSyntax
                )
            )
        } else if let recoveredTransactions = exactTransactionStatements(
            in: syntaxTree,
            source: nsSource
        ) {
            statements = recoveredTransactions
            unreliableStatementRanges = []
        } else {
            repairMergedTransactionBoundaries(
                statements: &statements,
                unreliableStatementRanges: &unreliableStatementRanges,
                syntaxTree: syntaxTree,
                source: nsSource
            )
            repairSemicolonBoundedUnreliableRanges(
                statements: &statements,
                unreliableStatementRanges: &unreliableStatementRanges,
                syntaxTree: syntaxTree,
                source: nsSource
            )
        }
        let currentRelationReferences = relationReferences(
            in: syntaxTree,
            source: nsSource
        )
        let relationReferences = Array(
            Set(currentRelationReferences + carriedRelationReferences)
        ).sorted { $0.range.location < $1.range.location }
        var reusedScopes: [Int: SQLQueryScopeSnapshot] = [:]
        for node in rootChildren where !node.hasChanges {
            guard let cached = reusedStatements[node.id], let scope = cached.scope else { continue }
            reusedScopes[node.range.location] = scope.shiftedForReuse(by: node.range.location - cached.syntax.range.location)
        }
        let queryScopes = queryScopes(
            in: syntaxTree,
            reusedScopes: reusedScopes,
            statements: statements,
            relationReferences: relationReferences,
            source: nsSource
        )
        return SQLParseSnapshot(
            revision: source.revision,
            sourceLength: (source.text as NSString).length,
            statements: statements.sorted { $0.range.location < $1.range.location },
            unreliableStatementRanges: unreliableStatementRanges.sorted {
                $0.location < $1.location
            },
            diagnostics: coalesceDiagnostics(diagnostics),
            changedRanges: changedRanges,
            mode: mode,
            syntaxTree: syntaxTree,
            relationReferences: relationReferences,
            queryScopes: queryScopes
        )
    }

    private struct QueryScopeNode {
        let node: SQLSyntaxNodeSnapshot
        let kind: SQLQueryScopeSnapshot.Kind
        let canReferenceParentRelations: Bool
    }

    private static func queryScopes(
        in syntaxTree: SQLSyntaxNodeSnapshot,
        reusedScopes: [Int: SQLQueryScopeSnapshot],
        statements: [SQLStatement],
        relationReferences: [SQLRelationReferenceSnapshot],
        source: NSString
    ) -> [SQLQueryScopeSnapshot] {
        let statementNodes = Dictionary(
            grouping: syntaxTree.descendants(named: "statement"),
            by: \.range.location
        )
        // References are sorted by source offset. Restrict each statement before
        // descending; scanning every document relation for every statement was O(n²).
        func references(in range: SQLSourceRange) -> [SQLRelationReferenceSnapshot] {
            var lower = 0, upper = relationReferences.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if relationReferences[middle].range.location < range.location { lower = middle + 1 }
                else { upper = middle }
            }
            let start = lower
            while lower < relationReferences.count, relationReferences[lower].range.location < range.upperBound { lower += 1 }
            return relationReferences[start..<lower].filter { range.contains($0.range) }
        }
        return statements.compactMap { statement in
            if let scope = reusedScopes[statement.range.location], scope.range == statement.range { return scope }
            guard let syntaxNode = statementNodes[statement.range.location]?
                .min(by: { $0.range.length < $1.range.length })
            else {
                return nil
            }
            let rootNode = SQLSyntaxNodeSnapshot(
                type: syntaxNode.type,
                range: statement.range,
                children: syntaxNode.children
            )
            return queryScope(
                for: QueryScopeNode(
                    node: rootNode,
                    kind: .statement,
                    canReferenceParentRelations: false
                ),
                relationReferences: references(in: statement.range),
                source: source
            )
        }
    }

    private static func queryScope(
        for scopeNode: QueryScopeNode,
        relationReferences: [SQLRelationReferenceSnapshot],
        source: NSString
    ) -> SQLQueryScopeSnapshot {
        let childNodes: [QueryScopeNode]
        if scopeNode.node.type == "set_operation" {
            childNodes = setOperationQueryBlocks(in: scopeNode.node)
        } else {
            childNodes = immediateQueryScopeNodes(
                in: scopeNode.node,
                source: source
            )
        }
        let children = childNodes.map {
            queryScope(
                for: $0,
                relationReferences: relationReferences,
                source: source
            )
        }
        let childRanges = children.map(\.range)
        let localRelations = relationReferences.filter { reference in
            scopeNode.node.range.contains(reference.range)
                && !childRanges.contains(where: { $0.contains(reference.range) })
        }
        let localTerms = descendants(
            named: "term",
            in: scopeNode.node,
            excluding: childRanges
        )
        var projectedColumnNames = uniqueIdentifiers(
            localTerms.compactMap {
                projectedColumnName(in: $0, source: source)
            }
        )
        if projectedColumnNames.isEmpty,
           scopeNode.node.type == "set_operation"
        {
            projectedColumnNames = children.first?.projectedColumnNames ?? []
        }
        let aliases = uniqueIdentifiers(
            localTerms.compactMap {
                directIdentifierText(in: $0, source: source)
            }
        )
        let namedWindows = uniqueIdentifiers(
            descendants(
                named: "window_clause",
                in: scopeNode.node,
                excluding: childRanges
            ).flatMap {
                directIdentifierTexts(in: $0, source: source)
            }
        )
        let syntheticRelations = syntheticRelations(
            in: scopeNode.node,
            childScopes: children,
            childRanges: childRanges,
            source: source
        )
        return SQLQueryScopeSnapshot(
            kind: scopeNode.kind,
            range: scopeNode.node.range,
            canReferenceParentRelations: scopeNode.canReferenceParentRelations,
            relationReferences: localRelations,
            syntheticRelations: syntheticRelations,
            projectedColumnNames: projectedColumnNames,
            selectListAliases: aliases,
            namedWindows: namedWindows,
            children: children
        )
    }

    private static func immediateQueryScopeNodes(
        in node: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> [QueryScopeNode] {
        var result: [QueryScopeNode] = []

        func collect(
            from current: SQLSyntaxNodeSnapshot,
            insideRelation: Bool,
            insideLateralJoin: Bool
        ) {
            for child in current.children {
                let childInsideRelation = insideRelation || child.type == "relation"
                let childInsideLateralJoin = insideLateralJoin
                    || ["lateral_join", "lateral_cross_join"].contains(child.type)
                let kind: SQLQueryScopeSnapshot.Kind? = switch child.type {
                case "subquery": .subquery
                case "cte":
                    .commonTableExpression(
                        name: firstIdentifierText(in: child, source: source)
                    )
                case "set_operation": .setOperation
                default: nil
                }
                if let kind {
                    result.append(
                        QueryScopeNode(
                            node: child,
                            kind: kind,
                            canReferenceParentRelations: child.type == "subquery"
                                ? (!childInsideRelation || childInsideLateralJoin)
                                : child.type == "set_operation"
                        )
                    )
                    continue
                }
                collect(
                    from: child,
                    insideRelation: childInsideRelation,
                    insideLateralJoin: childInsideLateralJoin
                )
            }
        }

        collect(from: node, insideRelation: false, insideLateralJoin: false)
        return result.sorted { $0.node.range.location < $1.node.range.location }
    }

    private static func setOperationQueryBlocks(
        in node: SQLSyntaxNodeSnapshot
    ) -> [QueryScopeNode] {
        let operationTypes: Set<String> = [
            "keyword_union", "keyword_except", "keyword_intersect",
        ]
        let operationLocations = node.children
            .filter { operationTypes.contains($0.type) }
            .map(\.range.location)
            .sorted()
        let lastSelectIndex = node.children.lastIndex {
            $0.type == "select"
        }
        let tailLocation = lastSelectIndex.flatMap {
            setOperationTailLocation(in: node, after: $0)
        }
        return node.children.enumerated().compactMap { index, child in
            guard child.type == "select" else { return nil }
            let end = operationLocations.first(where: {
                $0 > child.range.location
            }) ?? tailLocation ?? node.range.upperBound
            let range = SQLSourceRange(
                location: child.range.location,
                length: max(0, end - child.range.location)
            )
            let branchChildren = node.children[index...].prefix {
                $0.range.location < end
            }
            return QueryScopeNode(
                node: SQLSyntaxNodeSnapshot(
                    type: "query_block",
                    range: range,
                    children: Array(branchChildren)
                ),
                kind: .queryBlock,
                canReferenceParentRelations: true
            )
        }
    }

    private static func setOperationTailLocation(
        in node: SQLSyntaxNodeSnapshot,
        after selectIndex: Int
    ) -> Int? {
        guard selectIndex + 1 < node.children.count else { return nil }
        let tailTypes: Set<String> = ["order_by", "limit"]
        return node.children[(selectIndex + 1)...]
            .flatMap { child in
                let candidates = [child] + child.children
                return candidates.filter { tailTypes.contains($0.type) }
            }
            .map(\.range.location)
            .min()
    }

    private static func syntheticRelations(
        in node: SQLSyntaxNodeSnapshot,
        childScopes: [SQLQueryScopeSnapshot],
        childRanges: [SQLSourceRange],
        source: NSString
    ) -> [SQLQuerySyntheticRelationSnapshot] {
        var relations: [SQLQuerySyntheticRelationSnapshot] = []
        for child in node.descendants(named: "cte") where childScopes.contains(
            where: { $0.range == child.range }
        ) {
            let asLocation = child.descendants(named: "keyword_as")
                .first?.range.location ?? child.range.upperBound
            let identifiers = child.descendants(named: "identifier")
                .filter { $0.range.location < asLocation }
                .sorted { $0.range.location < $1.range.location }
                .compactMap { identifierText(in: $0, source: source) }
            guard let name = identifiers.first else { continue }
            let childScope = childScopes.first { $0.range == child.range }
            let outputNames = identifiers.count > 1
                ? Array(identifiers.dropFirst())
                : childScope?.projectedColumnNames ?? []
            relations.append(
                SQLQuerySyntheticRelationSnapshot(
                    kind: .commonTableExpression,
                    range: child.range,
                    name: name,
                    alias: nil,
                    outputColumnNames: uniqueIdentifiers(outputNames)
                )
            )
        }

        for relation in descendants(
            named: "relation",
            in: node,
            excluding: childRanges
        ) {
            guard let subquery = relation.descendants(named: "subquery").first
            else {
                continue
            }
            let aliasNode = relation.descendants(named: "identifier")
                .filter { !subquery.range.contains($0.range) }
                .sorted { $0.range.location < $1.range.location }
                .last
            guard let aliasNode,
                  let alias = identifierText(in: aliasNode, source: source)
            else {
                continue
            }
            let outputNames = childScopes.first {
                $0.range == subquery.range
            }?.projectedColumnNames ?? []
            relations.append(
                SQLQuerySyntheticRelationSnapshot(
                    kind: .derivedTable,
                    range: relation.range,
                    name: alias,
                    alias: alias,
                    outputColumnNames: outputNames
                )
            )
        }
        return relations
    }

    private static func descendants(
        named type: String,
        in node: SQLSyntaxNodeSnapshot,
        excluding excludedRanges: [SQLSourceRange]
    ) -> [SQLSyntaxNodeSnapshot] {
        func collect(
            from current: SQLSyntaxNodeSnapshot,
            isRoot: Bool
        ) -> [SQLSyntaxNodeSnapshot] {
            if !isRoot, excludedRanges.contains(where: {
                $0.contains(current.range)
            }) {
                return []
            }
            var result = current.type == type ? [current] : []
            for child in current.children {
                result.append(
                    contentsOf: collect(from: child, isRoot: false)
                )
            }
            return result
        }
        return collect(from: node, isRoot: true)
    }

    private static func projectedColumnName(
        in term: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> String? {
        if let alias = directIdentifierText(in: term, source: source) {
            return alias
        }
        return term.descendants(named: "identifier")
            .sorted { $0.range.location < $1.range.location }
            .last
            .flatMap { identifierText(in: $0, source: source) }
    }

    private static func directIdentifierText(
        in node: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> String? {
        directIdentifierTexts(in: node, source: source).last
    }

    private static func directIdentifierTexts(
        in node: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> [String] {
        node.children
            .filter { $0.type == "identifier" }
            .compactMap { identifierText(in: $0, source: source) }
    }

    private static func firstIdentifierText(
        in node: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> String? {
        return node.descendants(named: "identifier")
            .sorted { $0.range.location < $1.range.location }
            .first
            .flatMap { identifierText(in: $0, source: source) }
    }

    private static func identifierText(
        in node: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> String? {
        guard node.range.location >= 0,
              node.range.upperBound <= source.length
        else {
            return nil
        }
        let value = unquotedIdentifier(
            source.substring(with: node.range.nsRange)
        )
        return value.isEmpty ? nil : value
    }

    private static func uniqueIdentifiers(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter {
            seen.insert($0.lowercased()).inserted
        }
    }

    private static func relationReferences(
        in syntaxTree: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> [SQLRelationReferenceSnapshot] {
        return syntaxTree.descendants(named: "relation").compactMap { relation in
            guard let reference = relation.descendants(named: "object_reference").first
            else {
                return nil
            }
            let identifiers = reference.descendants(named: "identifier")
                .sorted { $0.range.location < $1.range.location }
                .compactMap { node -> String? in
                    guard node.range.upperBound <= source.length else { return nil }
                    return unquotedIdentifier(source.substring(with: node.range.nsRange))
                }
            guard let objectName = identifiers.last, !objectName.isEmpty else {
                return nil
            }
            let databaseName = identifiers.count > 1
                ? identifiers[identifiers.count - 2]
                : nil
            let alias = relation.descendants(named: "identifier")
                .filter {
                    $0.range.location < reference.range.location
                        || $0.range.upperBound > reference.range.upperBound
                }
                .sorted { $0.range.location < $1.range.location }
                .last
                .flatMap { node -> String? in
                    guard node.range.upperBound <= source.length else { return nil }
                    return unquotedIdentifier(source.substring(with: node.range.nsRange))
                }
            return SQLRelationReferenceSnapshot(
                range: relation.range,
                databaseName: databaseName,
                objectName: objectName,
                alias: alias
            )
        }
    }

    private static func carriedRelationReferences(
        from snapshot: SQLParseSnapshot,
        previousSource: String,
        source: String,
        edit: SQLSourceEdit
    ) -> [SQLRelationReferenceSnapshot] {
        let previousSource = previousSource as NSString
        let source = source as NSString
        let editRange = edit.replacedRange
        let delta = (edit.replacement as NSString).length - editRange.length
        return snapshot.relationReferences.compactMap { reference in
            let mappedRange: SQLSourceRange
            if reference.range.upperBound <= editRange.location {
                mappedRange = reference.range
            } else if reference.range.location >= editRange.upperBound {
                mappedRange = SQLSourceRange(
                    location: reference.range.location + delta,
                    length: reference.range.length
                )
            } else {
                return nil
            }
            guard reference.range.upperBound <= previousSource.length,
                  mappedRange.location >= 0,
                  mappedRange.upperBound <= source.length,
                  previousSource.substring(with: reference.range.nsRange)
                    == source.substring(with: mappedRange.nsRange)
            else {
                return nil
            }
            return SQLRelationReferenceSnapshot(
                range: mappedRange,
                databaseName: reference.databaseName,
                objectName: reference.objectName,
                alias: reference.alias
            )
        }
    }

    private static func unquotedIdentifier(_ value: String) -> String {
        guard value.count >= 2,
              value.hasPrefix("`"),
              value.hasSuffix("`")
        else {
            return value
        }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "``", with: "`")
    }

    /// Indexed child access rescans preceding siblings in tree-sitter. A cursor
    /// keeps traversal linear for documents containing thousands of statements.
    private static func childNodes(of node: Node) -> [Node] {
        guard node.childCount > 0 else { return [] }
        let cursor = node.treeCursor
        guard cursor.goToFirstChild() else { return [] }
        var children: [Node] = []
        children.reserveCapacity(node.childCount)
        repeat {
            if let child = cursor.currentNode { children.append(child) }
        } while cursor.gotoNextSibling()
        return children
    }

    private static func syntaxSnapshot(for node: Node, reusing cache: [UInt: CachedStatement] = [:]) -> SQLSyntaxNodeSnapshot {
        if !node.hasChanges, let cached = cache[node.id] {
            return cached.syntax.shiftedForReuse(by: node.range.location - cached.syntax.range.location)
        }
        return SQLSyntaxNodeSnapshot(
            type: node.nodeType ?? "unknown",
            range: SQLSourceRange(node.range),
            children: compactSyntaxChildren(of: node, reusing: cache)
        )
    }

    private static func compactSyntaxChildren(
        of node: Node,
        reusing cache: [UInt: CachedStatement]
    ) -> [SQLSyntaxNodeSnapshot] {
        var children: [SQLSyntaxNodeSnapshot] = []
        for child in childNodes(of: node) {
            let type = child.nodeType ?? "unknown"
            if child.childCount == 0 || formattingNodeTypes.contains(type) {
                children.append(syntaxSnapshot(for: child, reusing: cache))
            } else {
                children.append(contentsOf: compactSyntaxChildren(of: child, reusing: cache))
            }
        }
        return children
    }

    private static let formattingNodeTypes: Set<String> = [
        "statement",
        "cte",
        "set_operation",
        "subquery",
        "query_block",
        "select",
        "select_expression",
        "from",
        "join",
        "cross_join",
        "lateral_join",
        "lateral_cross_join",
        "where",
        "group_by",
        "having",
        "window_clause",
        "window_specification",
        "order_by",
        "limit",
        "delimiter_directive",
        "delimiter_value",
        "executable_comment",
        "optimizer_hint",
        "invocation",
        "identifier",
        "relation",
        "list",
        "object_reference",
        "field",
        "term",
        "ERROR",
    ]

    private static func syntaxKind(for captureName: String?) -> SQLSyntaxHighlight.Kind? {
        switch captureName {
        case "keyword", "keyword.operator", "conditional", "repeat", "storageclass":
            return .keyword
        case "comment":
            return .comment
        case "variable":
            return .variable
        case "field", "property":
            return .property
        case "function", "function.call":
            return .function
        case "number", "float":
            return .number
        case "string":
            return .string
        case "type":
            return .type
        case "type.builtin":
            return .builtinType
        case "type.qualifier":
            return .attribute
        case "operator":
            return .operator
        case "punctuation.bracket", "punctuation.delimiter":
            return .punctuation
        case "parameter":
            return .parameter
        case "boolean":
            return .boolean
        case "attribute":
            return .attribute
        default:
            return nil
        }
    }

    private static func syntaxPriority(_ kind: SQLSyntaxHighlight.Kind) -> Int {
        switch kind {
        case .comment: return 110
        case .number, .boolean: return 100
        case .function: return 90
        case .property: return 80
        case .type, .builtinType: return 70
        case .keyword: return 60
        case .attribute: return 50
        case .parameter, .variable: return 40
        case .string: return 30
        case .operator, .punctuation: return 20
        }
    }

    private static func analyzeSegment(
        nodes: [Node],
        terminatorEnd: Int?,
        source: NSString,
        reusedStatements: [UInt: CachedStatement],
        statements: inout [SQLStatement],
        unreliableStatementRanges: inout [SQLSourceRange],
        diagnostics: inout [SQLParseDiagnostic]
    ) {
        let significantNodes = nodes.filter { node in
            !Self.isOrdinaryComment(node)
        }
        guard !significantNodes.isEmpty else { return }
        if significantNodes.count == 1, let node = significantNodes.first, !node.hasChanges,
           let cached = reusedStatements[node.id] {
            statements.append(.init(kind: cached.kind, range: rangeCovering([node], terminatorEnd: terminatorEnd)))
            return
        }

        let segmentRange = rangeCovering(
            significantNodes,
            terminatorEnd: terminatorEnd
        )
        if let transactionKind = exactTransactionBoundaryKind(
            in: segmentRange,
            source: source
        ) {
            statements.append(
                SQLStatement(
                    kind: .transaction(transactionKind),
                    range: segmentRange
                )
            )
            return
        }

        let executableNodeTypes: Set<String> = [
            "statement", "transaction", "_commit", "_rollback",
        ]
        let statementNodes = significantNodes.filter {
            executableNodeTypes.contains($0.nodeType ?? "")
        }
        let hasUnsupportedTopLevelNode = significantNodes.contains { node in
            !executableNodeTypes.contains(node.nodeType ?? "")
        }
        for node in significantNodes {
            collectDiagnostics(in: node, into: &diagnostics)
        }

        guard statementNodes.count == 1,
              let statementNode = statementNodes.first,
              !hasUnsupportedTopLevelNode
        else {
            if !containsNestedStatementTerminator(
                in: significantNodes,
                source: source
            ) {
                statements.append(
                    SQLStatement(
                        kind: statementKind(for: significantNodes),
                        range: segmentRange
                    )
                )
                return
            }
            unreliableStatementRanges.append(segmentRange)
            if !diagnostics.contains(where: {
                NSIntersectionRange(
                    $0.range.nsRange,
                    segmentRange.nsRange
                ).length > 0
            }) {
                diagnostics.append(
                    SQLParseDiagnostic(
                        range: segmentRange,
                        reason: .unsupportedSyntax
                    )
                )
            }
            return
        }

        let statementStart = statementNode.range.location
        let statementEnd = max(
            statementNode.range.location + statementNode.range.length,
            terminatorEnd ?? 0
        )
        statements.append(
            SQLStatement(
                kind: (!statementNode.hasChanges ? reusedStatements[statementNode.id]?.kind : nil) ?? statementKind(for: statementNode),
                range: SQLSourceRange(
                    location: statementStart,
                    length: statementEnd - statementStart
                )
            )
        )
    }

    private static func statementKind(for nodes: [Node]) -> SQLStatementKind {
        let nodeTypes = nodes.reduce(into: Set<String>()) { result, node in
            result.formUnion(descendantNodeTypes(in: node))
        }
        return statementKind(
            nodeTypes: nodeTypes,
            hasUpdateWhereClause: false,
            hasDeleteWhereClause: false
        )
    }

    private static func containsNestedStatementTerminator(
        in nodes: [Node],
        source: NSString
    ) -> Bool {
        var pending = nodes
        while let node = pending.popLast() {
            for child in childNodes(of: node) {
                if isStatementTerminator(child, source: source) {
                    return true
                }
                pending.append(child)
            }
        }
        return false
    }

    private static func statementKind(for node: Node) -> SQLStatementKind {
        let nodeTypes = descendantNodeTypes(in: node)
        return statementKind(
            nodeTypes: nodeTypes,
            hasUpdateWhereClause: nodeTypes.contains("keyword_update") && hasOuterUpdateWhereClause(in: node),
            hasDeleteWhereClause: nodeTypes.contains("keyword_delete") && hasOuterDeleteWhereClause(in: node)
        )
    }

    private static func statementKind(
        for node: SQLSyntaxNodeSnapshot
    ) -> SQLStatementKind {
        let nodeTypes = descendantNodeTypes(in: node)
        return statementKind(
            nodeTypes: nodeTypes,
            hasUpdateWhereClause: node.children.contains { $0.type == "where" },
            hasDeleteWhereClause: node.children
                .first { $0.type == "from" }?
                .children.contains { $0.type == "where" } == true
        )
    }

    private static func statementKind(
        nodeTypes: Set<String>,
        hasUpdateWhereClause: Bool,
        hasDeleteWhereClause: Bool
    ) -> SQLStatementKind {
        if nodeTypes.contains("executable_comment") {
            return .unknown
        }
        if nodeTypes.contains("_truncate_statement")
            || nodeTypes.contains("keyword_truncate")
            || nodeTypes.contains("truncate")
        {
            return .ddl(.truncate)
        }
        if nodeTypes.contains("_drop_statement")
            || nodeTypes.contains("keyword_drop")
            || nodeTypes.contains(where: { $0.hasPrefix("drop_") })
        {
            return .ddl(.drop)
        }
        if nodeTypes.contains("_delete_statement")
            || nodeTypes.contains("keyword_delete")
            || nodeTypes.contains("delete")
        {
            return .delete(hasWhereClause: hasDeleteWhereClause)
        }
        if nodeTypes.contains("_update_statement")
            || nodeTypes.contains("_mysql_update_statement")
            || nodeTypes.contains("_postgres_update_statement")
            || nodeTypes.contains("keyword_update")
            || nodeTypes.contains("update")
        {
            return .update(hasWhereClause: hasUpdateWhereClause)
        }
        if nodeTypes.contains("_insert_statement")
            || nodeTypes.contains("keyword_insert")
            || nodeTypes.contains("insert")
        {
            return .insert
        }
        if nodeTypes.contains("_create_statement")
            || nodeTypes.contains("keyword_create")
            || nodeTypes.contains(where: { $0.hasPrefix("create_") })
        {
            return .ddl(.create)
        }
        if nodeTypes.contains("_alter_statement")
            || nodeTypes.contains("keyword_alter")
            || nodeTypes.contains(where: { $0.hasPrefix("alter_") })
        {
            return .ddl(.alter)
        }
        if nodeTypes.contains("_ddl_statement") {
            return .ddl(.other)
        }
        if nodeTypes.contains("_commit") || nodeTypes.contains("commit") {
            return .transaction(.commit)
        }
        if nodeTypes.contains("savepoint") {
            return .transaction(.savepoint)
        }
        if nodeTypes.contains("_rollback") || nodeTypes.contains("rollback") {
            return .transaction(.rollback)
        }
        if nodeTypes.contains("transaction")
            || nodeTypes.contains("start")
            || nodeTypes.contains("begin")
            || nodeTypes.contains("keyword_begin")
        {
            return .transaction(.begin)
        }
        if nodeTypes.contains("set_statement")
            || nodeTypes.contains("reset_statement")
            || nodeTypes.contains("use")
        {
            return .control
        }
        if nodeTypes.contains("select")
            || nodeTypes.contains("_select_statement")
            || nodeTypes.contains("_show_statement")
            || nodeTypes.contains("show")
            || nodeTypes.contains("keyword_show")
            || nodeTypes.contains("describe")
            || nodeTypes.contains("keyword_describe")
            || nodeTypes.contains("keyword_desc")
            || nodeTypes.contains("explain")
            || nodeTypes.contains("keyword_explain")
        {
            return .read
        }
        return .unknown
    }

    private static func repairMergedTransactionBoundaries(
        statements: inout [SQLStatement],
        unreliableStatementRanges: inout [SQLSourceRange],
        syntaxTree: SQLSyntaxNodeSnapshot,
        source: NSString
    ) {
        let segments = topLevelSyntaxSegments(in: syntaxTree)
        let transactionSegments = segments.compactMap { segment in
            exactTransactionBoundaryKind(in: segment.range, source: source).map {
                (range: segment.range, kind: $0)
            }
        }
        guard !transactionSegments.isEmpty else { return }

        let mergedStatements = statements.filter { statement in
            guard case .transaction = statement.kind else { return true }
            return false
        }.filter { statement in
            transactionSegments.contains { transaction in
                NSIntersectionRange(
                    statement.range.nsRange,
                    transaction.range.nsRange
                ).length > 0
            }
        }
        guard !mergedStatements.isEmpty else { return }

        let repairRange = mergedStatements.dropFirst().reduce(
            mergedStatements[0].range.nsRange
        ) { partial, statement in
            NSUnionRange(partial, statement.range.nsRange)
        }
        statements.removeAll { statement in
            NSIntersectionRange(statement.range.nsRange, repairRange).length > 0
        }
        unreliableStatementRanges.removeAll { range in
            NSIntersectionRange(range.nsRange, repairRange).length > 0
        }

        for segment in segments where
            NSIntersectionRange(segment.range.nsRange, repairRange).length > 0
        {
            if let transactionKind = exactTransactionBoundaryKind(
                in: segment.range,
                source: source
            ) {
                statements.append(
                    SQLStatement(
                        kind: .transaction(transactionKind),
                        range: segment.range
                    )
                )
                continue
            }

            let statementNodes = segment.nodes.filter { node in
                node.type == "statement"
                    && node.descendants(named: "ERROR").isEmpty
            }
            guard statementNodes.count == 1, let statementNode = statementNodes.first
            else {
                unreliableStatementRanges.append(segment.range)
                continue
            }
            statements.append(
                SQLStatement(
                    kind: statementKind(for: statementNode),
                    range: SQLSourceRange(
                        location: statementNode.range.location,
                        length: segment.range.upperBound - statementNode.range.location
                    )
                )
            )
        }
    }

    private static func topLevelSyntaxSegments(
        in syntaxTree: SQLSyntaxNodeSnapshot
    ) -> [(range: SQLSourceRange, nodes: [SQLSyntaxNodeSnapshot])] {
        var segments: [(range: SQLSourceRange, nodes: [SQLSyntaxNodeSnapshot])] = []
        var nodes: [SQLSyntaxNodeSnapshot] = []
        var start = syntaxTree.range.location

        for child in syntaxTree.children {
            guard child.type == ";" else {
                nodes.append(child)
                continue
            }
            segments.append((
                range: SQLSourceRange(
                    location: start,
                    length: child.range.upperBound - start
                ),
                nodes: nodes
            ))
            start = child.range.upperBound
            nodes.removeAll(keepingCapacity: true)
        }
        if start < syntaxTree.range.upperBound {
            segments.append((
                range: SQLSourceRange(
                    location: start,
                    length: syntaxTree.range.upperBound - start
                ),
                nodes: nodes
            ))
        }
        return segments
    }

    private static func repairSemicolonBoundedUnreliableRanges(
        statements: inout [SQLStatement],
        unreliableStatementRanges: inout [SQLSourceRange],
        syntaxTree: SQLSyntaxNodeSnapshot,
        source: NSString
    ) {
        guard !unreliableStatementRanges.isEmpty else { return }
        let terminators = syntaxRanges(named: ";", in: syntaxTree)
        guard !terminators.isEmpty
        else {
            return
        }

        var repairedStatements: [SQLStatement] = []
        var remainingUnreliableRanges: [SQLSourceRange] = []
        for unreliableRange in unreliableStatementRanges {
            let containedTerminators = terminators.filter {
                $0.location >= unreliableRange.location
                    && $0.upperBound <= unreliableRange.upperBound
            }
            guard !containedTerminators.isEmpty else {
                remainingUnreliableRanges.append(unreliableRange)
                continue
            }

            let existingStatements = statements.filter {
                $0.range.location >= unreliableRange.location
                    && $0.range.upperBound <= unreliableRange.upperBound
            }
            statements.removeAll {
                NSIntersectionRange(
                    $0.range.nsRange,
                    unreliableRange.nsRange
                ).length > 0
            }

            var segmentStart = unreliableRange.location
            for terminator in containedTerminators {
                let segmentRange = SQLSourceRange(
                    location: segmentStart,
                    length: terminator.upperBound - segmentStart
                )
                segmentStart = terminator.upperBound
                guard hasExecutablePayload(
                    in: segmentRange,
                    source: source
                ) else {
                    continue
                }

                let containedStatements = existingStatements.filter {
                    $0.range.location >= segmentRange.location
                        && $0.range.upperBound <= segmentRange.upperBound
                }
                let kind = exactTransactionBoundaryKind(
                    in: segmentRange,
                    source: source
                ).map(SQLStatementKind.transaction)
                    ?? (containedStatements.count == 1
                        ? containedStatements[0].kind
                        : .unknown)
                repairedStatements.append(
                    SQLStatement(kind: kind, range: segmentRange)
                )
            }

            guard segmentStart < unreliableRange.upperBound else {
                continue
            }
            let trailingRange = SQLSourceRange(
                location: segmentStart,
                length: unreliableRange.upperBound - segmentStart
            )
            if hasExecutablePayload(in: trailingRange, source: source) {
                remainingUnreliableRanges.append(trailingRange)
            }
        }

        statements.append(contentsOf: repairedStatements)
        unreliableStatementRanges = remainingUnreliableRanges
    }

    private static func hasExecutablePayload(
        in range: SQLSourceRange,
        source: NSString
    ) -> Bool {
        guard range.upperBound <= source.length else {
            return false
        }
        var payload = source
            .substring(with: range.nsRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasSuffix(";") {
            payload.removeLast()
            payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !payload.isEmpty
    }

    private static func exactTransactionBoundaryKind(
        in range: SQLSourceRange,
        source: NSString
    ) -> SQLStatementKind.TransactionOperation? {
        guard range.upperBound <= source.length else {
            return nil
        }
        var command = source
            .substring(with: range.nsRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if command.hasSuffix(";") {
            command.removeLast()
            command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let firstWord = command.prefix { !$0.isWhitespace && $0 != ";" }.uppercased()
        guard ["BEGIN", "SAVEPOINT", "RELEASE", "START", "COMMIT", "ROLLBACK"].contains(firstWord),
              !command.contains(";") else { return nil }
        let normalized = command
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .uppercased()

        switch normalized {
        case "BEGIN", "BEGIN WORK":
            return .begin
        default:
            if normalized.hasPrefix("SAVEPOINT ")
                || normalized.hasPrefix("RELEASE SAVEPOINT ")
                || normalized.hasPrefix("ROLLBACK TO ")
                || normalized.hasPrefix("ROLLBACK WORK TO ")
            {
                return .savepoint
            }
            if normalized == "START TRANSACTION"
                || normalized.hasPrefix("START TRANSACTION ")
            {
                return .begin
            }
            if normalized == "COMMIT"
                || normalized.hasPrefix("COMMIT ")
            {
                return .commit
            }
            if normalized == "ROLLBACK"
                || normalized.hasPrefix("ROLLBACK ")
            {
                return .rollback
            }
            return nil
        }
    }

    private static func exactTransactionStatements(
        in syntaxTree: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> [SQLStatement]? {
        let terminators = syntaxRanges(named: ";", in: syntaxTree)
        guard !terminators.isEmpty else { return nil }

        var statements: [SQLStatement] = []
        var statementStart = syntaxTree.range.location
        for terminator in terminators {
            let statementEnd = terminator.upperBound
            let range = SQLSourceRange(
                location: statementStart,
                length: statementEnd - statementStart
            )
            guard let kind = exactTransactionBoundaryKind(
                in: range,
                source: source
            ) else {
                return nil
            }
            statements.append(
                SQLStatement(kind: .transaction(kind), range: range)
            )
            statementStart = statementEnd
        }

        if statementStart < syntaxTree.range.upperBound {
            let trailingRange = SQLSourceRange(
                location: statementStart,
                length: syntaxTree.range.upperBound - statementStart
            )
            let trailingText = source
                .substring(with: trailingRange.nsRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trailingText.isEmpty else { return nil }
        }
        return statements
    }

    private static func directTerminatedStatements(
        inErrorNode node: Node,
        source: NSString
    ) -> [SQLStatement]? {
        guard node.nodeType == "ERROR" else { return nil }
        let terminators = childNodes(of: node).filter { isStatementTerminator($0, source: source) }
        guard !terminators.isEmpty else { return nil }

        let fallbackKind = terminators.count == 1
            ? statementKind(for: node)
            : .unknown
        var statements: [SQLStatement] = []
        var statementStart = node.range.location
        for terminator in terminators {
            let statementEnd = terminator.range.location + terminator.range.length
            let range = SQLSourceRange(
                location: statementStart,
                length: statementEnd - statementStart
            )
            let kind = exactTransactionBoundaryKind(
                in: range,
                source: source
            ).map(SQLStatementKind.transaction) ?? fallbackKind
            statements.append(
                SQLStatement(kind: kind, range: range)
            )
            statementStart = statementEnd
        }

        if statementStart < node.range.location + node.range.length {
            let trailingRange = SQLSourceRange(
                location: statementStart,
                length: node.range.location + node.range.length - statementStart
            )
            let trailingText = source
                .substring(with: trailingRange.nsRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trailingText.isEmpty else { return nil }
        }
        return statements
    }

    private static func isStatementTerminator(
        _ node: Node,
        source: NSString
    ) -> Bool {
        let range = node.range
        guard node.childCount == 0,
              range.length == 1,
              range.location >= 0,
              NSMaxRange(range) <= source.length
        else {
            return false
        }
        return source.substring(with: range) == ";"
    }

    private static func syntaxRanges(
        named type: String,
        in node: SQLSyntaxNodeSnapshot
    ) -> [SQLSourceRange] {
        var ranges: [SQLSourceRange] = []
        var pending = [node]
        while let current = pending.popLast() {
            if current.type == type {
                ranges.append(current.range)
                continue
            }
            pending.append(contentsOf: current.children)
        }
        return ranges.sorted { $0.location < $1.location }
    }

    private static func hasOuterUpdateWhereClause(in node: Node) -> Bool {
        syntaxSnapshot(for: node).children.contains { $0.type == "where" }
    }

    private static func hasOuterDeleteWhereClause(in node: Node) -> Bool {
        syntaxSnapshot(for: node).children
            .first { $0.type == "from" }?
            .children.contains { $0.type == "where" } == true
    }

    private static func descendantNodeTypes(in node: Node) -> Set<String> {
        var result: Set<String> = []
        var pending = [node]
        while let current = pending.popLast() {
            if let nodeType = current.nodeType {
                result.insert(nodeType.lowercased())
            }
            pending.append(contentsOf: childNodes(of: current))
        }
        return result
    }

    private static func descendantNodeTypes(
        in node: SQLSyntaxNodeSnapshot
    ) -> Set<String> {
        var result: Set<String> = []
        var pending = [node]
        while let current = pending.popLast() {
            result.insert(current.type.lowercased())
            pending.append(contentsOf: current.children)
        }
        return result
    }

    private static func collectDiagnostics(
        in node: Node,
        into diagnostics: inout [SQLParseDiagnostic]
    ) {
        guard node.hasError || node.isMissing else { return }
        if node.nodeType == "ERROR" {
            diagnostics.append(
                SQLParseDiagnostic(
                    range: SQLSourceRange(node.range),
                    reason: .syntaxError
                )
            )
            return
        }
        if node.isMissing {
            diagnostics.append(
                SQLParseDiagnostic(
                    range: SQLSourceRange(node.range),
                    reason: .missingSyntax
                )
            )
        }
        for child in childNodes(of: node) {
            collectDiagnostics(in: child, into: &diagnostics)
        }
    }

    private static func isOrdinaryComment(_ node: Node) -> Bool {
        node.nodeType == "comment" || node.nodeType == "marginalia"
    }

    private static func rangeCovering(
        _ nodes: [Node],
        terminatorEnd: Int?
    ) -> SQLSourceRange {
        let start = nodes.map(\.range.location).min() ?? 0
        let nodeEnd = nodes.map { $0.range.location + $0.range.length }.max() ?? start
        let end = max(nodeEnd, terminatorEnd ?? 0)
        return SQLSourceRange(location: start, length: end - start)
    }

    private static func coalesceDiagnostics(
        _ diagnostics: [SQLParseDiagnostic]
    ) -> [SQLParseDiagnostic] {
        Array(Set(diagnostics)).sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
    }

    private static func point(in text: String, at utf16Location: Int) -> Point {
        let source = text as NSString
        let safeLocation = min(max(0, utf16Location), source.length)
        var row = 0
        var lineStart = 0
        if safeLocation > 0 {
            for index in 0..<safeLocation where source.character(at: index) == 10 {
                row += 1
                lineStart = index + 1
            }
        }
        return Point(row: row, column: safeLocation - lineStart)
    }
}
