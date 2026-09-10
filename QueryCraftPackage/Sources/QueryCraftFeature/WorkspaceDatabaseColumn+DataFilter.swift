extension WorkspaceDatabaseColumn {
    var dataFilterKind: WorkspaceDatabaseDataFilterColumnKind {
        WorkspaceDatabaseDataFilterColumnKind(mysqlType: type)
    }

    var dataFilterMenuValues: [String] {
        dataFilterMenuValues(for: dataFilterKind)
    }

    func dataFilterMenuValues(
        for kind: WorkspaceDatabaseDataFilterColumnKind
    ) -> [String] {
        switch kind {
        case .boolean:
            return ["0", "1"]
        case .elasticsearchBoolean:
            return ["false", "true"]
        case .enumeration:
            return Self.parseEnumerationValues(from: type)
        case .text, .number, .date, .binary,
             .elasticsearchKeyword, .elasticsearchText,
             .elasticsearchTextWithKeyword, .elasticsearchNumber,
             .elasticsearchDate, .elasticsearchIP:
            return []
        }
    }

    var defaultDataFilterCondition: WorkspaceDatabaseDataFilterCondition {
        defaultDataFilterCondition(kind: dataFilterKind)
    }

    func defaultDataFilterCondition(
        mappingField: WorkspaceDocumentMappingField?
    ) -> WorkspaceDatabaseDataFilterCondition {
        defaultDataFilterCondition(
            kind: mappingField?.dataFilterKind ?? dataFilterKind
        )
    }

    private func defaultDataFilterCondition(
        kind: WorkspaceDatabaseDataFilterColumnKind
    ) -> WorkspaceDatabaseDataFilterCondition {
        let menuValues = dataFilterMenuValues(for: kind)
        return WorkspaceDatabaseDataFilterCondition(
            columnName: name,
            columnKind: kind,
            operation: WorkspaceDatabaseDataFilterOperator.available(
                for: kind
            )[0],
            value: kind.isElasticsearch ? "" : menuValues.first ?? ""
        )
    }

    private static func parseEnumerationValues(from mysqlType: String) -> [String] {
        guard
            let opening = mysqlType.firstIndex(of: "("),
            let closing = mysqlType.lastIndex(of: ")"),
            opening < closing
        else {
            return []
        }

        let body = mysqlType[mysqlType.index(after: opening)..<closing]
        var values: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false

        for character in body {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" && isQuoted {
                isEscaped = true
            } else if character == "'" {
                if isQuoted {
                    values.append(current)
                    current = ""
                }
                isQuoted.toggle()
            } else if isQuoted {
                current.append(character)
            }
        }
        return values
    }
}

extension WorkspaceDocumentMappingField {
    var dataFilterKind: WorkspaceDatabaseDataFilterColumnKind? {
        guard isIndexed, isSearchable, !hasTypeConflict else { return nil }
        let types = type.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard types.count == 1, let type = types.first else { return nil }
        return WorkspaceDatabaseDataFilterColumnKind(
            elasticsearchType: type,
            hasKeywordSubfield: keywordSubfieldPath != nil
        )
    }
}
