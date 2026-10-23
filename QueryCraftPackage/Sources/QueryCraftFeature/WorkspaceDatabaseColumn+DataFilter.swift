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
        WorkspaceSQLDataFilterColumn.menuValues(type: type, kind: kind)
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
        WorkspaceSQLDataFilterColumn.defaultCondition(name: name, type: type, kind: kind)
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
