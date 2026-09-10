import Foundation

enum SQLCompletionEngine {
    struct Request: Sendable {
        let source: SQLSourceSnapshot
        let cursorLocation: Int
        let parseSnapshot: SQLParseSnapshot
        let schemaCatalog: WorkspaceSchemaCatalogSnapshot
        let defaultDatabase: String?
        let databaseType: DatabaseType

        init(
            source: SQLSourceSnapshot,
            cursorLocation: Int,
            parseSnapshot: SQLParseSnapshot,
            schemaCatalog: WorkspaceSchemaCatalogSnapshot,
            defaultDatabase: String?,
            databaseType: DatabaseType = .mysql
        ) {
            self.source = source
            self.cursorLocation = cursorLocation
            self.parseSnapshot = parseSnapshot
            self.schemaCatalog = schemaCatalog
            self.defaultDatabase = defaultDatabase
            self.databaseType = databaseType
        }
    }

    static func completions(for request: Request) throws -> SQLCompletionResult? {
        try Task.checkCancellation()
        let source = request.source.text as NSString
        let dialect = SQLCompletionDialect.forDatabaseType(request.databaseType)
        guard request.parseSnapshot.revision == request.source.revision,
              request.parseSnapshot.sourceLength == source.length,
              request.cursorLocation >= 0,
              request.cursorLocation <= source.length,
              !isImmediatelyAfterSemicolon(request.cursorLocation, source: source)
        else {
            return nil
        }

        let replacementRange = identifierPrefixRange(
            endingAt: request.cursorLocation,
            source: source
        )
        let prefix = source.substring(with: replacementRange.nsRange)
        let specialComment = specialCommentContext(
            at: request.cursorLocation,
            in: request.parseSnapshot.syntaxTree
        )
        guard !isInsideExcludedSyntax(
            at: request.cursorLocation,
            in: request.parseSnapshot.syntaxTree,
            source: source
        ) else {
            return nil
        }
        let queryScopePath = request.parseSnapshot.queryScopePath(
            atUTF16Location: request.cursorLocation
        )
        let scope = queryScopePath.last?.range
            ?? structuralRange(
                at: request.cursorLocation,
                snapshot: request.parseSnapshot,
                source: request.source.text
            )
        let syntaxNode = scopedSyntaxNode(
            in: request.parseSnapshot.syntaxTree,
            range: scope,
            cursorLocation: request.cursorLocation
        )
        let tokens = syntaxTokens(in: syntaxNode, source: source)
        guard !isInsideExcludedToken(
            at: request.cursorLocation,
            replacementRange: replacementRange,
            tokens: tokens
        ) else {
            return nil
        }

        let qualifier = qualifier(
            before: replacementRange.location,
            source: source,
            tokens: tokens
        )
        let confidence = contextConfidence(
            scope: scope,
            snapshot: request.parseSnapshot,
            tokens: tokens,
            hasStructuralQueryScope: !queryScopePath.isEmpty
        )
        let syntheticRelations = visibleSyntheticRelations(
            in: queryScopePath
        )
        let projectedColumnNames = setOperationOutputColumnNames(
            in: queryScopePath
        )
        let bindings = relationBindings(
            references: request.parseSnapshot.relationReferences,
            tokens: tokens,
            scope: scope,
            queryScopePath: queryScopePath,
            syntheticRelations: syntheticRelations,
            source: source,
            catalog: request.schemaCatalog,
            defaultDatabase: request.defaultDatabase
        )
        let ordinaryContext = completionContext(
            qualifier: qualifier,
            replacementRange: replacementRange,
            tokens: tokens,
            confidence: confidence
        )
        let context: CompletionContext = switch specialComment {
        case .optimizerHint:
            CompletionContext(kind: .optimizerHint, confidence: .structural)
        case .executable:
            CompletionContext(kind: .general, confidence: .unknown)
        case nil:
            recoveredSetOperationContext(
                prefix: prefix,
                replacementRange: replacementRange,
                snapshot: request.parseSnapshot,
                ordinaryContext: ordinaryContext,
                dialect: dialect
            ) ?? ordinaryContext
        }
        let candidates = try makeCandidates(
            context: context,
            dialect: dialect,
            qualifier: qualifier,
            bindings: bindings,
            syntheticRelations: syntheticRelations,
            projectedColumnNames: projectedColumnNames,
            catalog: request.schemaCatalog,
            defaultDatabase: request.defaultDatabase,
            includeFallback: !prefix.isEmpty
        )
        let ranked = try SQLCompletionRanker.rank(
            candidates,
            prefix: prefix,
            replacementRange: replacementRange,
            revision: request.source.revision,
            limit: 200
        )
        try Task.checkCancellation()
        let missingColumnObjects = missingColumnObjects(
            for: bindings,
            catalog: request.schemaCatalog
        )
        let referencedSchemaObjects = referencedSchemaObjects(for: bindings)
        guard !ranked.isEmpty
                || !missingColumnObjects.isEmpty
                || !referencedSchemaObjects.isEmpty
        else {
            return nil
        }
        return SQLCompletionResult(
            sourceRevision: request.source.revision,
            windowLocation: replacementRange.location,
            items: ranked,
            referencedSchemaObjects: referencedSchemaObjects
        )
    }

    private static func referencedSchemaObjects(
        for bindings: [RelationBinding]
    ) -> [WorkspaceSchemaObjectReference] {
        var seen: Set<WorkspaceSchemaObjectReference> = []
        return bindings.compactMap { binding in
            guard let databaseName = binding.databaseName,
                  binding.object != nil
            else {
                return nil
            }
            let reference = WorkspaceSchemaObjectReference(
                databaseName: databaseName,
                objectName: binding.objectName
            )
            return seen.insert(reference).inserted ? reference : nil
        }
    }

    private static func missingColumnObjects(
        for bindings: [RelationBinding],
        catalog: WorkspaceSchemaCatalogSnapshot
    ) -> [WorkspaceSchemaObjectReference] {
        var seen: Set<WorkspaceSchemaObjectReference> = []
        return bindings.compactMap { binding in
            guard let databaseName = binding.databaseName,
                  let object = binding.object,
                  object.columns.isEmpty
            else {
                return nil
            }
            let reference = WorkspaceSchemaObjectReference(
                databaseName: databaseName,
                objectName: binding.objectName
            )
            guard !catalog.hasLoadedColumns(for: reference),
                  seen.insert(reference).inserted
            else {
                return nil
            }
            return reference
        }
    }

    private enum Context {
        case general
        case relation
        case statementStart
        case selectList
        case insertStart
        case insertBody
        case updateBody
        case assignment
        case deleteStart
        case ddlObjectType
        case ddlObjectTypeWithTemporary
        case ddlBody
        case postRelation
        case postJoinRelation
        case setOperation
        case predicate
        case grouping
        case ordering
        case limitTail
        case none
        case qualified
        case optimizerHint
    }

    private enum ContextConfidence {
        case structural
        case recovered
        case unknown
    }

    private struct CompletionContext {
        let kind: Context
        let confidence: ContextConfidence
    }

    private enum Clause {
        case select
        case from
        case join
        case whereClause
        case on
        case group
        case having
        case order
        case limit
        case offset
        case insert
        case replace
        case into
        case update
        case set
        case delete
        case create
        case alter
        case drop
        case truncate
        case table
        case values
    }

    private struct SyntaxToken {
        let type: String
        let text: String
        let range: SQLSourceRange
    }

    private struct RelationBinding {
        let alias: String?
        let databaseName: String?
        let objectName: String
        let object: WorkspaceSchemaObject?
    }

    private enum SpecialCommentContext {
        case optimizerHint
        case executable
    }

    private static func structuralRange(
        at location: Int,
        snapshot: SQLParseSnapshot,
        source: String
    ) -> SQLSourceRange? {
        let ranges = (snapshot.statements.map(\.range)
            + snapshot.unreliableStatementRanges)
            .sorted { $0.location < $1.location }
        if let containingRange = ranges.first(where: {
            location >= $0.location && location <= $0.upperBound
        }) {
            return containingRange
        }
        if let precedingRange = ranges.last(where: {
            $0.upperBound < location
        }), canExtendCompletionScope(
            precedingRange,
            to: location,
            source: source
        ) {
            return precedingRange
        }
        return snapshot.statement(atUTF16Location: location, in: source)?.range
    }

    private static func canExtendCompletionScope(
        _ range: SQLSourceRange,
        to location: Int,
        source: String
    ) -> Bool {
        let source = source as NSString
        guard range.upperBound > 0,
              range.upperBound < location,
              location <= source.length,
              source.substring(
                with: NSRange(location: range.upperBound - 1, length: 1)
              ) != ";"
        else {
            return false
        }
        return source.substring(
            with: NSRange(
                location: range.upperBound,
                length: location - range.upperBound
            )
        ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func scopedSyntaxNode(
        in root: SQLSyntaxNodeSnapshot,
        range: SQLSourceRange?,
        cursorLocation: Int
    ) -> SQLSyntaxNodeSnapshot {
        guard let range else {
            return SQLSyntaxNodeSnapshot(
                type: "completion_scope",
                range: SQLSourceRange(location: cursorLocation, length: 0),
                children: []
            )
        }
        let children = root.children.compactMap {
            clippedSyntaxNode($0, to: range)
        }
        return SQLSyntaxNodeSnapshot(
            type: "completion_scope",
            range: range,
            children: children
        )
    }

    private static func clippedSyntaxNode(
        _ node: SQLSyntaxNodeSnapshot,
        to range: SQLSourceRange
    ) -> SQLSyntaxNodeSnapshot? {
        guard rangesIntersectOrTouch(node.range, range) else {
            return nil
        }
        if range.contains(node.range) || node.isLeaf {
            return node
        }
        let children = node.children.compactMap {
            clippedSyntaxNode($0, to: range)
        }
        guard !children.isEmpty else { return nil }
        return SQLSyntaxNodeSnapshot(
            type: node.type,
            range: node.range,
            children: children
        )
    }

    private static func isInsideExcludedSyntax(
        at cursorLocation: Int,
        in node: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> Bool {
        let containsCursor = cursorLocation >= node.range.location
            && cursorLocation <= node.range.upperBound
        guard containsCursor else { return false }
        if ["comment", "literal"].contains(node.type) {
            return true
        }
        if node.type == "identifier",
           node.range.location >= 0,
           node.range.upperBound <= source.length,
           source.substring(with: node.range.nsRange).hasPrefix("`")
        {
            return true
        }
        return node.children.contains {
            isInsideExcludedSyntax(at: cursorLocation, in: $0, source: source)
        }
    }

    private static func specialCommentContext(
        at cursorLocation: Int,
        in node: SQLSyntaxNodeSnapshot
    ) -> SpecialCommentContext? {
        guard cursorLocation >= node.range.location,
              cursorLocation <= node.range.upperBound
        else {
            return nil
        }
        switch node.type {
        case "optimizer_hint":
            return .optimizerHint
        case "executable_comment":
            return .executable
        default:
            break
        }
        return node.children.lazy.compactMap {
            specialCommentContext(at: cursorLocation, in: $0)
        }.first
    }

    private static func syntaxTokens(
        in node: SQLSyntaxNodeSnapshot,
        source: NSString
    ) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        collectTokens(in: node, source: source, into: &tokens)
        return tokens.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }
    }

    private static func collectTokens(
        in node: SQLSyntaxNodeSnapshot,
        source: NSString,
        into tokens: inout [SyntaxToken]
    ) {
        guard node.range.location >= 0,
              node.range.upperBound <= source.length
        else {
            return
        }
        if node.isLeaf || node.type == "identifier" {
            tokens.append(
                SyntaxToken(
                    type: node.type,
                    text: source.substring(with: node.range.nsRange),
                    range: node.range
                )
            )
            return
        }
        for child in node.children {
            collectTokens(in: child, source: source, into: &tokens)
        }
    }

    private static func identifierPrefixRange(
        endingAt cursorLocation: Int,
        source: NSString
    ) -> SQLSourceRange {
        var start = cursorLocation
        while start > 0,
              isIdentifierCodeUnit(source.character(at: start - 1))
        {
            start -= 1
        }
        return SQLSourceRange(location: start, length: cursorLocation - start)
    }

    private static func isIdentifierCodeUnit(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(value) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
            || value == 95
            || value == 36
    }

    private static func isInsideExcludedToken(
        at cursorLocation: Int,
        replacementRange: SQLSourceRange,
        tokens: [SyntaxToken]
    ) -> Bool {
        tokens.contains { token in
            let containsCursor = cursorLocation >= token.range.location
                && cursorLocation <= token.range.upperBound
            guard containsCursor else { return false }
            if ["comment", "literal"].contains(token.type) {
                return true
            }
            return token.type == "identifier"
                && token.text.hasPrefix("`")
                && replacementRange.location > token.range.location
        }
    }

    private static func qualifier(
        before prefixLocation: Int,
        source: NSString,
        tokens: [SyntaxToken]
    ) -> String? {
        guard prefixLocation > 0,
              source.substring(
                with: NSRange(location: prefixLocation - 1, length: 1)
              ) == "."
        else {
            return nil
        }
        let dotLocation = prefixLocation - 1
        if let identifier = tokens.last(where: {
            $0.type == "identifier" && $0.range.upperBound <= dotLocation
        }) {
            let between = NSRange(
                location: identifier.range.upperBound,
                length: dotLocation - identifier.range.upperBound
            )
            if source.substring(with: between)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            {
                return unquotedIdentifier(identifier.text)
            }
        }
        let directRange = identifierPrefixRange(
            endingAt: dotLocation,
            source: source
        )
        guard directRange.length > 0 else { return nil }
        return source.substring(with: directRange.nsRange)
    }

    private static func completionContext(
        qualifier: String?,
        replacementRange: SQLSourceRange,
        tokens: [SyntaxToken],
        confidence: ContextConfidence
    ) -> CompletionContext {
        if qualifier != nil {
            return CompletionContext(
                kind: .qualified,
                confidence: confidence == .unknown ? .recovered : confidence
            )
        }

        let precedingTokens = tokens.filter {
            $0.range.upperBound <= replacementRange.location
                && !["comment", "marginalia"].contains($0.type)
        }
        guard let previous = precedingTokens.last else {
            return CompletionContext(
                kind: confidence == .unknown ? .general : .statementStart,
                confidence: confidence
            )
        }

        if isRelationIntroducer(previous)
            || isDDLRelationIntroducer(
                previous,
                precedingTokens: precedingTokens
            )
        {
            return CompletionContext(
                kind: .relation,
                confidence: locallyRecovered(confidence)
            )
        }
        guard let clause = precedingTokens.reversed().compactMap({
            clause(for: $0)
        }).first else {
            return CompletionContext(kind: .general, confidence: confidence)
        }

        if previous.text == ",", [.from, .join].contains(clause) {
            return CompletionContext(kind: .relation, confidence: confidence)
        }

        let kind: Context = switch clause {
        case .select:
            .selectList
        case .insert, .replace:
            .insertStart
        case .into:
            .insertBody
        case .update:
            .updateBody
        case .set:
            .assignment
        case .delete:
            .deleteStart
        case .create, .drop:
            previous.text.caseInsensitiveCompare("TEMPORARY") == .orderedSame
                ? .ddlObjectType
                : .ddlObjectTypeWithTemporary
        case .alter, .truncate:
            .ddlObjectType
        case .table:
            .ddlBody
        case .values:
            .general
        case .from:
            .postRelation
        case .join:
            .postJoinRelation
        case .whereClause, .on, .having:
            .predicate
        case .group:
            .grouping
        case .order:
            .ordering
        case .limit:
            previous.type == "keyword_limit" ? .none : .limitTail
        case .offset:
            .none
        }
        return CompletionContext(
            kind: kind,
            confidence: locallyRecovered(confidence)
        )
    }

    private static func locallyRecovered(
        _ confidence: ContextConfidence
    ) -> ContextConfidence {
        confidence == .unknown ? .recovered : confidence
    }

    private static func recoveredSetOperationContext(
        prefix: String,
        replacementRange: SQLSourceRange,
        snapshot: SQLParseSnapshot,
        ordinaryContext: CompletionContext,
        dialect: SQLCompletionDialect
    ) -> CompletionContext? {
        let normalizedPrefix = prefix.uppercased()
        let isQueryTailContext = switch ordinaryContext.kind {
        case .postRelation, .postJoinRelation, .predicate, .grouping,
             .ordering, .limitTail, .none:
            true
        default:
            false
        }
        guard !normalizedPrefix.isEmpty,
              isQueryTailContext,
              dialect.setOperationKeywords.contains(where: {
                  $0.hasPrefix(normalizedPrefix)
              }),
              snapshot.statements.contains(where: {
                  $0.kind == .read && $0.range.contains(replacementRange)
              }),
              snapshot.diagnostics.contains(where: { diagnostic in
                  NSIntersectionRange(
                      diagnostic.range.nsRange,
                      replacementRange.nsRange
                  ).length > 0
              })
        else {
            return nil
        }
        return CompletionContext(kind: .setOperation, confidence: .structural)
    }

    private static func contextConfidence(
        scope: SQLSourceRange?,
        snapshot: SQLParseSnapshot,
        tokens: [SyntaxToken],
        hasStructuralQueryScope: Bool
    ) -> ContextConfidence {
        guard let scope else { return .unknown }
        if hasStructuralQueryScope
            || snapshot.statements.contains(where: { $0.range == scope })
        {
            return .structural
        }
        if tokens.contains(where: { token in
            token.type != "ERROR"
                && !["comment", "marginalia"].contains(token.type)
        }) {
            return .recovered
        }
        return .unknown
    }

    private static func clause(for token: SyntaxToken) -> Clause? {
        let structuralClause: Clause? = switch token.type {
        case "keyword_select": .select
        case "keyword_from": .from
        case "keyword_join": .join
        case "keyword_where": .whereClause
        case "keyword_on": .on
        case "keyword_group": .group
        case "keyword_having": .having
        case "keyword_order": .order
        case "keyword_limit": .limit
        case "keyword_offset": .offset
        case "keyword_insert": .insert
        case "keyword_replace": .replace
        case "keyword_into": .into
        case "keyword_update": .update
        case "keyword_set": .set
        case "keyword_delete": .delete
        case "keyword_create": .create
        case "keyword_alter": .alter
        case "keyword_drop": .drop
        case "keyword_truncate": .truncate
        case "keyword_table": .table
        case "keyword_values": .values
        default: nil
        }
        if let structuralClause { return structuralClause }
        return switch normalizedTokenText(token) {
        case "SELECT": .select
        case "FROM": .from
        case "JOIN": .join
        case "WHERE": .whereClause
        case "ON": .on
        case "GROUP": .group
        case "HAVING": .having
        case "ORDER": .order
        case "LIMIT": .limit
        case "OFFSET": .offset
        case "INSERT": .insert
        case "REPLACE": .replace
        case "INTO": .into
        case "UPDATE": .update
        case "SET": .set
        case "DELETE": .delete
        case "CREATE": .create
        case "ALTER": .alter
        case "DROP": .drop
        case "TRUNCATE": .truncate
        case "TABLE": .table
        case "VALUES": .values
        default: nil
        }
    }

    private static func relationBindings(
        references: [SQLRelationReferenceSnapshot],
        tokens: [SyntaxToken],
        scope: SQLSourceRange?,
        queryScopePath: [SQLQueryScopeSnapshot],
        syntheticRelations: [SQLQuerySyntheticRelationSnapshot],
        source: NSString,
        catalog: WorkspaceSchemaCatalogSnapshot,
        defaultDatabase: String?
    ) -> [RelationBinding] {
        guard let scope else { return [] }
        let visibleScopes = visibleRelationScopes(in: queryScopePath)
        var scopedReferences = visibleScopes.isEmpty
            ? references.filter { rangesIntersectOrTouch($0.range, scope) }
            : visibleScopes.flatMap(\.relationReferences)
        for recovered in recoveredRelationReferences(
            tokens: tokens,
            source: source
        ) where !scopedReferences.contains(where: {
            sameRelation($0, recovered)
        }) {
            scopedReferences.append(recovered)
        }

        var bindings = scopedReferences.flatMap { reference -> [RelationBinding] in
            if let synthetic = syntheticRelations.first(where: {
                $0.name.caseInsensitiveCompare(reference.objectName)
                    == .orderedSame
            }) {
                return [
                    syntheticBinding(
                        for: synthetic,
                        alias: reference.alias
                    ),
                ]
            }
            guard let databaseName = reference.databaseName ?? defaultDatabase else {
                return []
            }
            let database = catalog.database(named: databaseName)
            return [
                RelationBinding(
                    alias: reference.alias,
                    databaseName: database?.name ?? databaseName,
                    objectName: database?.object(named: reference.objectName)?.name
                        ?? reference.objectName,
                    object: database?.object(named: reference.objectName)
                )
            ]
        }
        for synthetic in syntheticRelations {
            let syntheticName = synthetic.alias ?? synthetic.name
            if synthetic.kind == .derivedTable {
                bindings.removeAll {
                    identifiersEqual(
                        $0.alias ?? $0.objectName,
                        syntheticName
                    )
                }
                bindings.append(
                    syntheticBinding(for: synthetic, alias: synthetic.alias)
                )
            } else if !bindings.contains(where: {
                identifiersEqual(
                    $0.alias ?? $0.objectName,
                    syntheticName
                )
            }) {
                bindings.append(
                    syntheticBinding(for: synthetic, alias: synthetic.alias)
                )
            }
        }

        var seen: Set<String> = []
        return bindings.filter { binding in
            let key = (binding.alias ?? binding.objectName).lowercased()
            return seen.insert(key).inserted
        }
    }

    private static func visibleRelationScopes(
        in path: [SQLQueryScopeSnapshot]
    ) -> [SQLQueryScopeSnapshot] {
        var result: [SQLQueryScopeSnapshot] = []
        for scope in path.reversed() {
            result.append(scope)
            if !scope.canReferenceParentRelations {
                break
            }
        }
        return result
    }

    private static func visibleSyntheticRelations(
        in path: [SQLQueryScopeSnapshot]
    ) -> [SQLQuerySyntheticRelationSnapshot] {
        let relationScopes = visibleRelationScopes(in: path)
        var relations = relationScopes.flatMap(\.syntheticRelations)
        relations += path.flatMap(\.syntheticRelations).filter {
            $0.kind == .commonTableExpression
        }
        var seen: Set<String> = []
        return relations.filter {
            seen.insert(($0.alias ?? $0.name).lowercased()).inserted
        }
    }

    private static func setOperationOutputColumnNames(
        in path: [SQLQueryScopeSnapshot]
    ) -> [String] {
        guard path.last?.kind == .setOperation else { return [] }
        return path.last?.projectedColumnNames ?? []
    }

    private static func syntheticBinding(
        for relation: SQLQuerySyntheticRelationSnapshot,
        alias: String?
    ) -> RelationBinding {
        RelationBinding(
            alias: alias ?? relation.alias,
            databaseName: nil,
            objectName: relation.name,
            object: WorkspaceSchemaObject(
                name: relation.name,
                kind: .view,
                columns: relation.outputColumnNames.enumerated().map {
                    WorkspaceSchemaColumn(
                        name: $0.element,
                        type: "query output",
                        ordinalPosition: $0.offset + 1
                    )
                }
            )
        )
    }

    private static func recoveredRelationReferences(
        tokens: [SyntaxToken],
        source: NSString
    ) -> [SQLRelationReferenceSnapshot] {
        var references: [SQLRelationReferenceSnapshot] = []
        var relationListIsActive = false
        var index = 0
        while index < tokens.count {
            let canStartRelation = isRelationIntroducer(tokens[index])
                || (relationListIsActive && tokens[index].text == ",")
            guard canStartRelation,
                  let parsed = recoveredRelationReference(
                    after: index,
                    tokens: tokens,
                    source: source
                  )
            else {
                relationListIsActive = false
                index += 1
                continue
            }
            references.append(parsed.reference)
            relationListIsActive = true
            index = max(index + 1, parsed.resumeIndex)
        }
        return references
    }

    private static func recoveredRelationReference(
        after introducerIndex: Int,
        tokens: [SyntaxToken],
        source: NSString
    ) -> (reference: SQLRelationReferenceSnapshot, resumeIndex: Int)? {
        let firstIndex = introducerIndex + 1
        guard firstIndex < tokens.count,
              isIdentifierToken(tokens[firstIndex])
        else {
            return nil
        }

        var databaseName: String?
        var objectToken = tokens[firstIndex]
        var nextIndex = firstIndex + 1
        if nextIndex + 1 < tokens.count,
           tokens[nextIndex].text == ".",
           isIdentifierToken(tokens[nextIndex + 1])
        {
            databaseName = unquotedIdentifier(objectToken.text)
            objectToken = tokens[nextIndex + 1]
            nextIndex += 2
        }

        let objectName = unquotedIdentifier(objectToken.text)
        guard !objectName.isEmpty else { return nil }
        let boundaryIndex = tokens[nextIndex...].firstIndex(where: {
            isRelationBoundary($0)
        })
        let boundaryLocation = boundaryIndex.map { tokens[$0].range.location }
        let explicitAlias = recoveredAlias(
            after: objectToken,
            startingAt: nextIndex,
            before: boundaryIndex,
            tokens: tokens,
            source: source
        )
        let alias = explicitAlias?.name ?? boundaryLocation.flatMap {
            recoveredAlias(
                between: objectToken.range.upperBound,
                and: $0,
                source: source
            )
        }
        let upperBound = boundaryLocation
            ?? explicitAlias?.upperBound
            ?? objectToken.range.upperBound
        return (
            SQLRelationReferenceSnapshot(
                range: SQLSourceRange(
                    location: tokens[introducerIndex].range.location,
                    length: max(0, upperBound - tokens[introducerIndex].range.location)
                ),
                databaseName: databaseName,
                objectName: objectName,
                alias: alias
            ),
            boundaryIndex ?? nextIndex
        )
    }

    private static func isRelationIntroducer(_ token: SyntaxToken) -> Bool {
        [
            "keyword_from", "keyword_join", "keyword_into", "keyword_update",
        ].contains(token.type)
            || ["FROM", "JOIN", "INTO", "UPDATE"]
                .contains(normalizedTokenText(token))
    }

    private static func isDDLRelationIntroducer(
        _ token: SyntaxToken,
        precedingTokens: [SyntaxToken]
    ) -> Bool {
        guard normalizedTokenText(token) == "TABLE" else {
            return false
        }
        return precedingTokens.contains {
            ["ALTER", "DROP", "TRUNCATE"]
                .contains(normalizedTokenText($0))
        }
    }

    private static func isRelationBoundary(_ token: SyntaxToken) -> Bool {
        if [",", ";"].contains(token.text) { return true }
        return [
            "FROM", "JOIN", "LEFT", "RIGHT", "INNER", "CROSS", "WHERE",
            "ON", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION",
            "SET", "VALUES",
        ].contains(normalizedTokenText(token))
    }

    private static func normalizedTokenText(_ token: SyntaxToken) -> String {
        token.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isIdentifierToken(_ token: SyntaxToken) -> Bool {
        token.type == "identifier"
    }

    private static func recoveredAlias(
        after objectToken: SyntaxToken,
        startingAt index: Int,
        before boundaryIndex: Int?,
        tokens: [SyntaxToken],
        source: NSString
    ) -> (name: String, upperBound: Int)? {
        let limit = boundaryIndex ?? tokens.count
        guard index < limit else { return nil }

        var aliasIndex = index
        if tokens[aliasIndex].text.caseInsensitiveCompare("AS") == .orderedSame {
            aliasIndex += 1
        }
        guard aliasIndex < limit,
              isIdentifierToken(tokens[aliasIndex]),
              !isRelationBoundary(tokens[aliasIndex]),
              isWhitespace(
                between: objectToken.range.upperBound,
                and: tokens[index].range.location,
                source: source
              ),
              isRecoveredIdentifier(tokens[aliasIndex].text)
        else {
            return nil
        }
        return (
            unquotedIdentifier(tokens[aliasIndex].text),
            tokens[aliasIndex].range.upperBound
        )
    }

    private static func recoveredAlias(
        between start: Int,
        and end: Int,
        source: NSString
    ) -> String? {
        guard start >= 0, end >= start, end <= source.length else { return nil }
        let text = source.substring(
            with: NSRange(location: start, length: end - start)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        var components = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if components.first?.caseInsensitiveCompare("AS") == .orderedSame {
            components.removeFirst()
        }
        guard components.count == 1,
              isRecoveredIdentifier(components[0])
        else {
            return nil
        }
        return unquotedIdentifier(components[0])
    }

    private static func isWhitespace(
        between start: Int,
        and end: Int,
        source: NSString
    ) -> Bool {
        guard start >= 0, end >= start, end <= source.length else { return false }
        return source.substring(
            with: NSRange(location: start, length: end - start)
        ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isRecoveredIdentifier(_ value: String) -> Bool {
        if value.count >= 2, value.hasPrefix("`"), value.hasSuffix("`") {
            return true
        }
        let value = value as NSString
        guard value.length > 0 else { return false }
        return (0..<value.length).allSatisfy {
            isIdentifierCodeUnit(value.character(at: $0))
        }
    }

    private static func sameRelation(
        _ lhs: SQLRelationReferenceSnapshot,
        _ rhs: SQLRelationReferenceSnapshot
    ) -> Bool {
        identifiersEqual(lhs.databaseName, rhs.databaseName)
            && lhs.objectName.caseInsensitiveCompare(rhs.objectName) == .orderedSame
            && identifiersEqual(lhs.alias, rhs.alias)
    }

    private static func identifiersEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.caseInsensitiveCompare(rhs) == .orderedSame
        default:
            false
        }
    }

    private static func makeCandidates(
        context: CompletionContext,
        dialect: SQLCompletionDialect,
        qualifier: String?,
        bindings: [RelationBinding],
        syntheticRelations: [SQLQuerySyntheticRelationSnapshot],
        projectedColumnNames: [String],
        catalog: WorkspaceSchemaCatalogSnapshot,
        defaultDatabase: String?,
        includeFallback: Bool
    ) throws -> [SQLCompletionCandidate] {
        try Task.checkCancellation()
        if context.kind == .qualified, let qualifier {
            if let syntheticRelation = syntheticRelations.first(where: {
                identifiersEqual($0.alias ?? $0.name, qualifier)
            }) {
                return try columnCandidates(
                    for: syntheticBinding(
                        for: syntheticRelation,
                        alias: syntheticRelation.alias
                    ),
                    priority: 0
                )
            }
            if let aliasBinding = bindings.first(where: {
                $0.alias?.caseInsensitiveCompare(qualifier) == .orderedSame
            }) {
                return try columnCandidates(for: aliasBinding, priority: 0)
            }
            if let database = catalog.database(named: qualifier) {
                return try objectCandidates(in: database, qualified: false, priority: 0)
            }
            if let objectBinding = bindings.first(where: {
                $0.objectName.caseInsensitiveCompare(qualifier) == .orderedSame
            }) {
                return try columnCandidates(for: objectBinding, priority: 0)
            }
            return includeFallback
                ? try columnCandidates(for: bindings, priority: 0)
                : []
        }

        if context.confidence == .unknown {
            guard includeFallback else { return [] }
            return try generalCandidates(
                dialect: dialect,
                bindings: bindings,
                catalog: catalog,
                defaultDatabase: defaultDatabase,
                priority: 0,
                rankingGroup: 0
            )
        }

        let fallbackPriority = switch context.confidence {
        case .structural: 1_000
        case .recovered: 600
        case .unknown: 0
        }
        let fallback = includeFallback
            ? try generalCandidates(
                dialect: dialect,
                bindings: projectedColumnNames.isEmpty ? bindings : [],
                catalog: catalog,
                defaultDatabase: defaultDatabase,
                priority: fallbackPriority,
                rankingGroup: 1
            )
            : []

        let primary: [SQLCompletionCandidate] = switch context.kind {
        case .qualified:
            []

        case .relation:
            try relationCandidates(
                catalog: catalog,
                defaultDatabase: defaultDatabase
            )
                + syntheticRelationCandidates(syntheticRelations)

        case .statementStart:
            keywordCandidates(dialect.statementKeywords)
                + functionCandidates(dialect.functions, priority: 20)

        case .selectList:
            keywordCandidates(dialect.selectListKeywords)
                + (try columnCandidates(for: bindings, priority: 10))
                + functionCandidates(dialect.functions, priority: 20)

        case .insertStart:
            keywordCandidates(dialect.insertKeywords)

        case .insertBody:
            try columnCandidates(for: bindings, priority: 0)
                + keywordCandidates(
                    dialect.insertBodyKeywords,
                    priority: 30
                )

        case .updateBody:
            keywordCandidates(dialect.updateBodyKeywords)

        case .assignment:
            try columnCandidates(for: bindings, priority: 0)
                + functionCandidates(dialect.functions, priority: 20)
                + keywordCandidates(
                    dialect.assignmentKeywords,
                    priority: 40
                )

        case .deleteStart:
            keywordCandidates(dialect.deleteKeywords)

        case .ddlObjectType:
            keywordCandidates(dialect.ddlObjectTypeKeywords)

        case .ddlObjectTypeWithTemporary:
            keywordCandidates(
                dialect.ddlObjectTypeKeywordsWithTemporary
            )

        case .ddlBody:
            keywordCandidates(dialect.dataTypes)
                + keywordCandidates(dialect.ddlBodyKeywords, priority: 40)

        case .postRelation:
            keywordCandidates(dialect.postRelationKeywords)

        case .postJoinRelation:
            keywordCandidates(dialect.postJoinRelationKeywords)

        case .setOperation:
            keywordCandidates(dialect.setOperationKeywords)

        case .predicate:
            try columnCandidates(for: bindings, priority: 0)
                + functionCandidates(dialect.functions, priority: 20)
                + keywordCandidates(
                    dialect.predicateKeywords,
                    priority: 40
                )

        case .grouping:
            try columnCandidates(for: bindings, priority: 0)
                + functionCandidates(dialect.functions, priority: 20)
                + keywordCandidates(
                    dialect.groupingKeywords,
                    priority: 40
                )

        case .ordering:
            (projectedColumnNames.isEmpty
                ? try columnCandidates(for: bindings, priority: 0)
                : projectedColumnCandidates(projectedColumnNames))
                + functionCandidates(dialect.functions, priority: 20)
                + keywordCandidates(
                    dialect.orderingKeywords,
                    priority: 40
                )

        case .limitTail:
            keywordCandidates(["OFFSET"])

        case .none:
            []

        case .general:
            try generalCandidates(
                dialect: dialect,
                bindings: bindings,
                catalog: catalog,
                defaultDatabase: defaultDatabase,
                priority: 0,
                rankingGroup: 0
            )

        case .optimizerHint:
            keywordCandidates(dialect.optimizerHints)
                + aliasCandidates(for: bindings)
        }
        return primary + fallback
    }

    private static func projectedColumnCandidates(
        _ names: [String]
    ) -> [SQLCompletionCandidate] {
        names.enumerated().map { index, name in
            SQLCompletionCandidate(
                label: name,
                insertionText: name,
                detail: "query output",
                kind: .queryOutput,
                rankingGroup: 0,
                contextPriority: index,
                cursorOffset: 0
            )
        }
    }

    private static func syntheticRelationCandidates(
        _ relations: [SQLQuerySyntheticRelationSnapshot],
        priority: Int = 0,
        rankingGroup: Int = 0
    ) -> [SQLCompletionCandidate] {
        relations.enumerated().map { index, relation in
            SQLCompletionCandidate(
                label: relation.name,
                insertionText: relation.name,
                detail: relation.kind == .commonTableExpression
                    ? "common table expression"
                    : "derived table",
                kind: .view,
                rankingGroup: rankingGroup,
                contextPriority: priority + index,
                cursorOffset: 0
            )
        }
    }

    private static func aliasCandidates(
        for bindings: [RelationBinding]
    ) -> [SQLCompletionCandidate] {
        bindings.enumerated().compactMap { index, binding in
            guard let alias = binding.alias else { return nil }
            return SQLCompletionCandidate(
                label: alias,
                insertionText: alias,
                detail: "query alias",
                kind: .table,
                rankingGroup: 0,
                contextPriority: 200 + index,
                cursorOffset: 0
            )
        }
    }

    private static func generalCandidates(
        dialect: SQLCompletionDialect,
        bindings: [RelationBinding],
        catalog: WorkspaceSchemaCatalogSnapshot,
        defaultDatabase: String?,
        priority: Int,
        rankingGroup: Int
    ) throws -> [SQLCompletionCandidate] {
        try columnCandidates(
            for: bindings,
            priority: priority,
            rankingGroup: rankingGroup
        )
            + (try relationCandidates(
                catalog: catalog,
                defaultDatabase: defaultDatabase,
                priority: priority,
                rankingGroup: rankingGroup
            ))
            + keywordCandidates(
                dialect.keywords,
                priority: priority + 20,
                rankingGroup: rankingGroup
            )
            + functionCandidates(
                dialect.functions,
                priority: priority + 60,
                rankingGroup: rankingGroup
            )
    }

    private static func relationCandidates(
        catalog: WorkspaceSchemaCatalogSnapshot,
        defaultDatabase: String?,
        priority: Int = 0,
        rankingGroup: Int = 0
    ) throws -> [SQLCompletionCandidate] {
        try Task.checkCancellation()
        let databasePriority = priority + (defaultDatabase == nil ? 0 : 20)
        var candidates: [SQLCompletionCandidate] = []
        candidates.reserveCapacity(catalog.databases.count)
        for (index, database) in catalog.databases.enumerated() {
            try checkCancellation(at: index)
            candidates.append(SQLCompletionCandidate(
                label: database.name,
                insertionText: database.name,
                detail: "database",
                kind: .database,
                rankingGroup: rankingGroup,
                contextPriority: databasePriority,
                cursorOffset: 0
            ))
        }
        if let defaultDatabase,
           let database = catalog.database(named: defaultDatabase)
        {
            candidates += try objectCandidates(
                in: database,
                qualified: false,
                priority: priority,
                rankingGroup: rankingGroup
            )
        } else {
            for (index, database) in catalog.databases.enumerated() {
                try checkCancellation(at: index)
                candidates += try objectCandidates(
                    in: database,
                    qualified: true,
                    priority: priority + 20,
                    rankingGroup: rankingGroup
                )
            }
        }
        return candidates
    }

    private static func keywordCandidates(
        _ keywords: [String],
        priority: Int = 0,
        rankingGroup: Int = 0
    ) -> [SQLCompletionCandidate] {
        keywords.enumerated().map { index, keyword in
            SQLCompletionCandidate(
                label: keyword,
                insertionText: keyword,
                detail: "keyword",
                kind: .keyword,
                rankingGroup: rankingGroup,
                contextPriority: priority + index,
                cursorOffset: 0
            )
        }
    }

    private static func functionCandidates(
        _ functions: [String],
        priority: Int,
        rankingGroup: Int = 0
    ) -> [SQLCompletionCandidate] {
        functions.enumerated().map { index, function in
            SQLCompletionCandidate(
                label: function,
                insertionText: "\(function)()",
                detail: "function",
                kind: .function,
                rankingGroup: rankingGroup,
                contextPriority: priority + index,
                cursorOffset: -1,
                allowsFuzzyMatch: false
            )
        }
    }

    private static func columnCandidates(
        for bindings: [RelationBinding],
        priority: Int,
        rankingGroup: Int = 0
    ) throws -> [SQLCompletionCandidate] {
        var candidates: [SQLCompletionCandidate] = []
        for (index, binding) in bindings.enumerated() {
            try checkCancellation(at: index)
            candidates += try columnCandidates(
                for: binding,
                priority: priority + index,
                rankingGroup: rankingGroup
            )
        }
        return candidates
    }

    private static func columnCandidates(
        for binding: RelationBinding,
        priority: Int,
        rankingGroup: Int = 0
    ) throws -> [SQLCompletionCandidate] {
        guard let object = binding.object else { return [] }
        let qualifier = binding.alias ?? binding.objectName
        var candidates: [SQLCompletionCandidate] = []
        candidates.reserveCapacity(object.columns.count)
        for (index, column) in object.columns.enumerated() {
            try checkCancellation(at: index)
            candidates.append(SQLCompletionCandidate(
                label: column.name,
                insertionText: column.name,
                detail: columnDetail(
                    type: column.type,
                    qualifier: qualifier,
                    objectName: binding.objectName
                ),
                kind: .column,
                rankingGroup: rankingGroup,
                contextPriority: priority,
                cursorOffset: 0
            ))
        }
        return candidates
    }

    private static func columnDetail(
        type: String,
        qualifier: String,
        objectName: String
    ) -> String {
        if qualifier.caseInsensitiveCompare(objectName) == .orderedSame {
            return "\(type) · \(objectName)"
        }
        return "\(type) · \(qualifier) · \(objectName)"
    }

    private static func objectCandidates(
        in database: WorkspaceSchemaDatabase,
        qualified: Bool,
        priority: Int,
        rankingGroup: Int = 0
    ) throws -> [SQLCompletionCandidate] {
        var candidates: [SQLCompletionCandidate] = []
        candidates.reserveCapacity(database.objects.count)
        for (index, object) in database.objects.enumerated() {
            try checkCancellation(at: index)
            let name = qualified ? "\(database.name).\(object.name)" : object.name
            candidates.append(SQLCompletionCandidate(
                label: name,
                insertionText: name,
                detail: database.name,
                kind: object.kind == .table ? .table : .view,
                rankingGroup: rankingGroup,
                contextPriority: priority,
                cursorOffset: 0
            ))
        }
        return candidates
    }

    private static func checkCancellation(at index: Int) throws {
        if index.isMultiple(of: 128) {
            try Task.checkCancellation()
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

    private static func isImmediatelyAfterSemicolon(
        _ location: Int,
        source: NSString
    ) -> Bool {
        location > 0
            && source.substring(with: NSRange(location: location - 1, length: 1)) == ";"
    }

    private static func rangesIntersectOrTouch(
        _ lhs: SQLSourceRange,
        _ rhs: SQLSourceRange
    ) -> Bool {
        lhs.location <= rhs.upperBound && rhs.location <= lhs.upperBound
    }
}
