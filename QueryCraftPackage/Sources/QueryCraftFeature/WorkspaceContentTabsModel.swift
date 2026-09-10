import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceContentTabsModel {
    private(set) var contentItems: [WorkspaceContentTabItem] = [] {
        didSet { contentRevision &+= 1 }
    }
    private(set) var contentRevision = 0
    private(set) var selectedContentID: WorkspaceContentTabID?

    var items: [WorkspaceQueryTabItem] {
        contentItems.compactMap { item in
            guard case let .query(queryItem) = item else { return nil }
            return queryItem
        }
    }

    var selectedDocumentID: UUID? {
        guard case let .queryDocument(documentID) = selectedContentID else {
            return nil
        }
        return documentID
    }

    var selectedItem: WorkspaceQueryTabItem? {
        guard let selectedDocumentID else { return nil }
        return items.first { $0.id == selectedDocumentID }
    }

    var selectedContentItem: WorkspaceContentTabItem? {
        guard let selectedContentID else { return nil }
        return contentItems.first { $0.id == selectedContentID }
    }

    func append(_ item: WorkspaceQueryTabItem) {
        let contentItem = WorkspaceContentTabItem.query(item)
        contentItems = contentItems + [contentItem]
        selectedContentID = contentItem.id
    }

    func restore(
        queryItems: [WorkspaceQueryTabItem],
        elasticsearchRequestDocuments:
            [WorkspaceElasticsearchRequestDocumentModel] = [],
        contentOrder: [WorkspaceContentTabID],
        selecting contentID: WorkspaceContentTabID?
    ) {
        let queryItemsByID = Dictionary(
            uniqueKeysWithValues: queryItems.map { ($0.id, $0) }
        )
        let requestDocumentsByID = Dictionary(
            uniqueKeysWithValues: elasticsearchRequestDocuments.map {
                ($0.id, $0)
            }
        )
        var restoredItems: [WorkspaceContentTabItem] = []
        var restoredIDs: Set<WorkspaceContentTabID> = []

        for contentID in contentOrder {
            let item: WorkspaceContentTabItem?
            switch contentID {
            case let .queryDocument(documentID):
                item = queryItemsByID[documentID].map {
                    .query($0)
                }
            case let .databaseObject(selection):
                item = .databaseObject(selection)
            case .newTable:
                item = nil
            case let .redisKey(reference):
                item = .redisKey(reference)
            case .redisCommand:
                item = nil
            case let .elasticsearchRequest(documentID):
                item = requestDocumentsByID[documentID].map {
                    .elasticsearchRequest($0)
                }
            }
            guard let item, restoredIDs.insert(item.id).inserted else {
                continue
            }
            restoredItems.append(item)
        }

        for queryItem in queryItems {
            let contentItem = WorkspaceContentTabItem.query(queryItem)
            guard restoredIDs.insert(contentItem.id).inserted else { continue }
            restoredItems.append(contentItem)
        }
        for document in elasticsearchRequestDocuments {
            let contentItem = WorkspaceContentTabItem.elasticsearchRequest(
                document
            )
            guard restoredIDs.insert(contentItem.id).inserted else { continue }
            restoredItems.append(contentItem)
        }

        contentItems = restoredItems
        if let contentID,
           restoredIDs.contains(contentID)
        {
            selectedContentID = contentID
        } else {
            selectedContentID = restoredItems.last?.id
        }
    }

    func open(_ selection: WorkspaceDatabaseObjectSelection) {
        let contentID = WorkspaceContentTabID.databaseObject(selection)
        if contentItems.contains(where: { $0.id == contentID }) {
            selectedContentID = contentID
            return
        }
        contentItems.append(.databaseObject(selection))
        selectedContentID = contentID
    }

    func open(_ reference: RedisKeyReference) {
        let contentID = WorkspaceContentTabID.redisKey(reference)
        if contentItems.contains(where: { $0.id == contentID }) {
            selectedContentID = contentID
            return
        }
        contentItems.append(.redisKey(reference))
        selectedContentID = contentID
    }

    func append(_ document: WorkspaceRedisCommandDocumentModel) {
        let contentItem = WorkspaceContentTabItem.redisCommand(document)
        contentItems = contentItems + [contentItem]
        selectedContentID = contentItem.id
    }

    func append(_ document: WorkspaceElasticsearchRequestDocumentModel) {
        let contentItem = WorkspaceContentTabItem.elasticsearchRequest(document)
        contentItems = contentItems + [contentItem]
        selectedContentID = contentItem.id
    }

    func move(_ contentID: WorkspaceContentTabID, to destination: Int) {
        guard let source = contentItems.firstIndex(where: { $0.id == contentID })
        else { return }
        let boundedDestination = min(max(destination, 0), contentItems.count - 1)
        guard source != boundedDestination else { return }
        var reordered = contentItems
        let item = reordered.remove(at: source)
        reordered.insert(item, at: boundedDestination)
        contentItems = reordered
    }

    func move(_ contentID: WorkspaceContentTabID, by offset: Int) {
        guard let source = contentItems.firstIndex(where: { $0.id == contentID })
        else { return }
        move(contentID, to: source + offset)
    }

    func canMove(_ contentID: WorkspaceContentTabID, by offset: Int) -> Bool {
        guard let source = contentItems.firstIndex(where: { $0.id == contentID })
        else { return false }
        return contentItems.indices.contains(source + offset)
    }

    func select(at index: Int) {
        guard contentItems.indices.contains(index) else { return }
        select(contentItems[index].id)
    }

    func select(offsetBy offset: Int) {
        guard !contentItems.isEmpty else { return }
        let current = selectedContentID.flatMap { selected in
            contentItems.firstIndex(where: { $0.id == selected })
        } ?? 0
        let count = contentItems.count
        select(contentItems[(current + offset % count + count) % count].id)
    }

    func append(_ draft: WorkspaceNewTableDraft) {
        let contentItem = WorkspaceContentTabItem.newTable(draft)
        contentItems = contentItems + [contentItem]
        selectedContentID = contentItem.id
    }

    func replaceNewTable(
        _ draftID: UUID,
        with selection: WorkspaceDatabaseObjectSelection
    ) {
        let oldContentID = WorkspaceContentTabID.newTable(draftID)
        let newContentID = WorkspaceContentTabID.databaseObject(selection)
        guard let oldIndex = contentItems.firstIndex(where: {
            $0.id == oldContentID
        }) else {
            open(selection)
            return
        }

        if let existingIndex = contentItems.firstIndex(where: {
            $0.id == newContentID
        }), existingIndex != oldIndex {
            contentItems.remove(at: oldIndex)
        } else {
            contentItems[oldIndex] = .databaseObject(selection)
        }
        selectedContentID = newContentID
    }

    func replaceDatabaseObject(
        _ oldSelection: WorkspaceDatabaseObjectSelection,
        with newSelection: WorkspaceDatabaseObjectSelection
    ) {
        let oldContentID = WorkspaceContentTabID.databaseObject(oldSelection)
        let newContentID = WorkspaceContentTabID.databaseObject(newSelection)
        guard let oldIndex = contentItems.firstIndex(where: {
            $0.id == oldContentID
        }) else {
            return
        }

        if let existingIndex = contentItems.firstIndex(where: {
            $0.id == newContentID
        }), existingIndex != oldIndex {
            contentItems.remove(at: oldIndex)
        } else {
            contentItems[oldIndex] = .databaseObject(newSelection)
        }
        if selectedContentID == oldContentID {
            selectedContentID = newContentID
        }
    }

    func replaceRedisKey(
        _ oldReference: RedisKeyReference,
        with newReference: RedisKeyReference
    ) {
        let oldContentID = WorkspaceContentTabID.redisKey(oldReference)
        let newContentID = WorkspaceContentTabID.redisKey(newReference)
        guard let oldIndex = contentItems.firstIndex(where: {
            $0.id == oldContentID
        }) else { return }

        if let existingIndex = contentItems.firstIndex(where: {
            $0.id == newContentID
        }), existingIndex != oldIndex {
            contentItems.remove(at: oldIndex)
        } else {
            contentItems[oldIndex] = .redisKey(newReference)
        }
        if selectedContentID == oldContentID {
            selectedContentID = newContentID
        }
    }

    func select(_ documentID: UUID) {
        select(.queryDocument(documentID))
    }

    func select(_ contentID: WorkspaceContentTabID) {
        guard selectedContentID != contentID,
              contentItems.contains(where: { $0.id == contentID })
        else {
            return
        }
        selectedContentID = contentID
    }

    func contentIDs(
        for action: WorkspaceContentTabAction
    ) -> [WorkspaceContentTabID] {
        let contentIDs = contentItems.map(\.id)
        switch action {
        case let .close(contentID):
            return contentIDs.contains(contentID) ? [contentID] : []
        case let .closeOthers(contentID):
            guard contentIDs.contains(contentID) else { return [] }
            return contentIDs.filter { $0 != contentID }
        case let .closeToRight(contentID):
            guard let index = contentIDs.firstIndex(of: contentID) else {
                return []
            }
            return Array(contentIDs.dropFirst(index + 1))
        case .closeAll:
            return contentIDs
        }
    }

    @discardableResult
    func remove(_ documentID: UUID) -> UUID? {
        removeContent(.queryDocument(documentID))
        return selectedDocumentID
    }

    @discardableResult
    func removeContent(
        _ contentID: WorkspaceContentTabID
    ) -> WorkspaceContentTabID? {
        guard let index = contentItems.firstIndex(where: {
            $0.id == contentID
        }) else {
            return selectedContentID
        }

        if selectedContentID == contentID {
            if index + 1 < contentItems.count {
                selectedContentID = contentItems[index + 1].id
            } else if index > 0 {
                selectedContentID = contentItems[index - 1].id
            } else {
                selectedContentID = nil
            }
        }
        contentItems.remove(at: index)
        return selectedContentID
    }
}
