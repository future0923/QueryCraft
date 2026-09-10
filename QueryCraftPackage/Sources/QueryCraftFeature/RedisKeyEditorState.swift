import Foundation
import Observation

@MainActor
@Observable
final class RedisKeyEditorState {
    private(set) var details: RedisKeyDetails?
    var stringValue = ""
    private(set) var stringData = RedisBinaryValue(data: Data())
    private(set) var originalStringData = RedisBinaryValue(data: Data())
    private(set) var stringTotalByteCount = 0
    private(set) var isStringFullyLoaded = true
    private(set) var stringFormatError: RedisKeyEditError?
    var stringEditingFormat = RedisValueDisplayFormat.text
    var stringDisplayValue = "" {
        didSet {
            guard !isApplyingStringPresentation else { return }
            switch stringEditingFormat {
            case .text, .json:
                stringValue = stringDisplayValue
                stringData = RedisBinaryValue(utf8: stringDisplayValue)
                stringFormatError = nil
            case .hex:
                guard let data = RedisHexCodec.parse(stringDisplayValue) else {
                    stringFormatError = .invalidHex
                    return
                }
                stringData = RedisBinaryValue(data: data)
                stringValue = String(decoding: data, as: UTF8.self)
                stringFormatError = nil
            }
        }
    }
    var rows: [RedisKeyEditableRow] = []
    private(set) var selectedRowIDs: Set<RedisKeyEditableRow.ID> = []
    var expirationMode = RedisKeyExpirationMode.persistent
    var ttlMillisecondsText = ""
    private(set) var collectionContinuation: RedisCollectionContinuation?
    private(set) var collectionTotalCount: Int?
    private(set) var collectionScannedCount = 0
    private(set) var collectionMatchingCount: Int?
    private(set) var supportsHashFieldExpiration = false
    private(set) var reachedCollectionLimit = false
    private(set) var usesPagedCollection = false

    @ObservationIgnored private var isApplyingStringPresentation = false
    @ObservationIgnored private var pagedBaselineRows: [RedisKeyEditableRow] = []
    @ObservationIgnored private var pagedBaselineContinuation:
        RedisCollectionContinuation?
    @ObservationIgnored private var pagedBaselineTotalCount: Int?
    @ObservationIgnored private var pagedBaselineScannedCount = 0
    @ObservationIgnored private var pagedBaselineMatchingCount: Int?
    @ObservationIgnored private var pagedBaselineSupportsHashFieldExpiration = false
    @ObservationIgnored private var pagedBaselineReachedLimit = false

    var supportsValueEditing: Bool {
        guard let details else { return false }
        return switch details.reference.type {
        case .string:
            isStringFullyLoaded && stringTotalByteCount <= 100 * 1_024 * 1_024
        case .hash, .set, .sortedSet:
            true
        case .list:
            usesPagedCollection
        case .stream, .module, .unknown, .none:
            false
        }
    }

    var supportsStringPresentationEditing: Bool {
        guard supportsValueEditing else { return false }
        return stringEditingFormat != .text
            || stringData.losslessUTF8String != nil
    }

    var stringTextPresentation: String {
        let decoded = String(decoding: stringData.data, as: UTF8.self)
        guard stringData.losslessUTF8String == nil else { return decoded }
        return decoded.replacingOccurrences(of: "\0", with: "\\0")
    }

    var supportsRowEditing: Bool {
        guard let type = details?.reference.type else { return false }
        return type == .hash || type == .set || type == .sortedSet
            || (type == .list && usesPagedCollection)
    }

    var hasChanges: Bool {
        guard let details else { return false }
        return hasRawChanges(comparedWith: details)
    }

    var validationError: RedisKeyEditError? {
        guard hasChanges else { return nil }
        if let stringFormatError { return stringFormatError }
        do {
            _ = try mutationPlan()
            return nil
        } catch let error as RedisKeyEditError {
            return error
        } catch {
            return .unavailable
        }
    }

    func load(_ details: RedisKeyDetails) {
        self.details = details
        stringValue = details.value.rows.first?.first ?? ""
        stringData = RedisBinaryValue(utf8: stringValue)
        originalStringData = stringData
        stringTotalByteCount = stringData.data.count
        isStringFullyLoaded = !details.value.isTruncated
        stringFormatError = nil
        stringEditingFormat = .text
        applyStringPresentation(stringValue)
        rows = details.value.rows.map { row in
            RedisKeyEditableRow(
                isNew: false,
                firstValue: row.first ?? "",
                secondValue: row.count > 1 ? row[1] : ""
            )
        }
        selectedRowIDs = []
        collectionContinuation = nil
        collectionTotalCount = nil
        collectionScannedCount = 0
        collectionMatchingCount = nil
        supportsHashFieldExpiration = false
        reachedCollectionLimit = false
        usesPagedCollection = false
        pagedBaselineRows = []
        pagedBaselineContinuation = nil
        pagedBaselineTotalCount = nil
        pagedBaselineScannedCount = 0
        pagedBaselineMatchingCount = nil
        pagedBaselineSupportsHashFieldExpiration = false
        pagedBaselineReachedLimit = false
        expirationMode = details.ttlMilliseconds == nil ? .persistent : .expires
        ttlMillisecondsText = details.ttlMilliseconds.map(String.init) ?? ""
    }

    func discard() {
        guard let details else { return }
        if usesPagedCollection {
            rows = pagedBaselineRows
            selectedRowIDs = []
            collectionContinuation = pagedBaselineContinuation
            collectionTotalCount = pagedBaselineTotalCount
            collectionScannedCount = pagedBaselineScannedCount
            collectionMatchingCount = pagedBaselineMatchingCount
            supportsHashFieldExpiration =
                pagedBaselineSupportsHashFieldExpiration
            reachedCollectionLimit = pagedBaselineReachedLimit
            expirationMode = details.ttlMilliseconds == nil
                ? .persistent
                : .expires
            ttlMillisecondsText = details.ttlMilliseconds.map(String.init) ?? ""
            return
        }
        load(details)
    }

    func addRow() {
        guard supportsRowEditing else { return }
        let row: RedisKeyEditableRow
        if details?.reference.type == .list {
            row = RedisKeyEditableRow(
                isNew: true,
                firstValue: AppCopy.current.text("新", "New"),
                secondValue: "",
                insertionEdge: .tail
            )
        } else {
            row = RedisKeyEditableRow(isNew: true, firstValue: "")
        }
        rows.append(row)
        selectedRowIDs = [row.id]
    }

    func addListRow(at edge: RedisListInsertionEdge) {
        guard details?.reference.type == .list, supportsRowEditing else { return }
        let row = RedisKeyEditableRow(
            isNew: true,
            firstValue: AppCopy.current.text("新", "New"),
            secondValue: "",
            insertionEdge: edge
        )
        if edge == .head {
            rows.insert(row, at: 0)
        } else {
            rows.append(row)
        }
        selectedRowIDs = [row.id]
    }

    func removeRow(id: RedisKeyEditableRow.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else {
            return
        }
        if rows[index].isNew {
            rows.remove(at: index)
            if selectedRowIDs.contains(id) {
                selectedRowIDs = nearestRowID(to: index).map { [$0] } ?? []
            } else {
                selectedRowIDs.remove(id)
            }
        } else {
            rows[index].isDeleted.toggle()
        }
    }

    var selectedRowIndexes: IndexSet {
        IndexSet(rows.indices.filter { selectedRowIDs.contains(rows[$0].id) })
    }

    var selectedRows: [RedisKeyEditableRow] {
        rows.filter { selectedRowIDs.contains($0.id) && !$0.isDeleted }
    }

    var isCollectionFullyLoaded: Bool {
        usesPagedCollection && collectionContinuation == nil
            && !reachedCollectionLimit
    }

    func selectRows(_ indexes: IndexSet) {
        selectedRowIDs = Set(indexes.compactMap { index in
            rows.indices.contains(index) ? rows[index].id : nil
        })
    }

    func removeRows(at indexes: IndexSet) {
        let rowIDs = indexes.compactMap { index in
            rows.indices.contains(index) ? rows[index].id : nil
        }
        rowIDs.forEach(removeRow)
    }

    func updateRow(
        id: RedisKeyEditableRow.ID,
        cell: RedisKeyEditableCell,
        value: String
    ) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else {
            return
        }
        switch cell {
        case .firstValue:
            rows[index].firstValue = value
        case .secondValue:
            rows[index].secondValue = value
        case .thirdValue:
            rows[index].thirdValue = value
        }
    }

    func loadCollectionPage(
        _ page: RedisCollectionPage,
        replacing: Bool
    ) {
        let loadedRows = page.entries.map(Self.editableRow)
        if replacing {
            rows = Array(loadedRows.prefix(500_000))
            selectedRowIDs = []
        } else {
            let available = max(0, 500_000 - rows.count)
            rows.append(contentsOf: loadedRows.prefix(available))
        }
        collectionContinuation = page.continuation
        collectionTotalCount = page.totalCount
        collectionScannedCount = page.scannedCount
        collectionMatchingCount = page.matchingCount
        supportsHashFieldExpiration = page.supportsHashFieldExpiration
        reachedCollectionLimit = page.reachedRetainedLimit
            || rows.count >= 500_000
        usesPagedCollection = true
        pagedBaselineRows = rows
        pagedBaselineContinuation = collectionContinuation
        pagedBaselineTotalCount = collectionTotalCount
        pagedBaselineScannedCount = collectionScannedCount
        pagedBaselineMatchingCount = collectionMatchingCount
        pagedBaselineSupportsHashFieldExpiration =
            supportsHashFieldExpiration
        pagedBaselineReachedLimit = reachedCollectionLimit
    }

    var canLoadMoreCollectionRows: Bool {
        usesPagedCollection
            && collectionContinuation != nil
            && !reachedCollectionLimit
            && !hasChanges
    }

    private static func editableRow(
        from entry: RedisCollectionEntry
    ) -> RedisKeyEditableRow {
        switch entry {
        case let .list(index, value):
            let presentation = presentation(for: value)
            return RedisKeyEditableRow(
                isNew: false,
                firstValue: String(index),
                secondValue: presentation.text,
                originalSecondData: value,
                originalIndex: index,
                isBinaryReadOnly: presentation.isHex
            )
        case let .hash(field, value, ttlMilliseconds):
            let fieldPresentation = presentation(for: field)
            let valuePresentation = presentation(for: value)
            return RedisKeyEditableRow(
                isNew: false,
                firstValue: fieldPresentation.text,
                secondValue: valuePresentation.text,
                thirdValue: ttlMilliseconds.map(String.init) ?? "",
                originalFirstData: field,
                originalSecondData: value,
                isBinaryReadOnly: fieldPresentation.isHex
                    || valuePresentation.isHex
            )
        case let .set(member):
            let presentation = presentation(for: member)
            return RedisKeyEditableRow(
                isNew: false,
                firstValue: presentation.text,
                originalFirstData: member,
                isBinaryReadOnly: presentation.isHex
            )
        case let .sortedSet(member, score):
            let presentation = presentation(for: member)
            return RedisKeyEditableRow(
                isNew: false,
                firstValue: presentation.text,
                secondValue: score,
                originalFirstData: member,
                originalSecondData: RedisBinaryValue(utf8: score),
                isBinaryReadOnly: presentation.isHex
            )
        }
    }

    private static func presentation(
        for value: RedisBinaryValue
    ) -> (text: String, isHex: Bool) {
        if let text = value.losslessUTF8String {
            return (text, false)
        }
        return (
            "0x" + value.data.map { String(format: "%02x", $0) }.joined(),
            true
        )
    }

    func applyStringPresentation(_ value: String) {
        isApplyingStringPresentation = true
        stringDisplayValue = value
        isApplyingStringPresentation = false
    }

    func synchronizeStringPresentation() {
        if stringEditingFormat == .hex {
            applyStringPresentation(RedisHexCodec.format(stringData.data))
            return
        }
        if stringEditingFormat == .json,
           stringData.losslessUTF8String == nil
        {
            stringEditingFormat = .text
        }
        applyStringPresentation(stringTextPresentation)
    }

    func loadStringChunk(
        _ chunk: RedisStringChunk,
        replacing: Bool
    ) {
        var data = replacing ? Data() : stringData.data
        if replacing, chunk.offset > 0 {
            data.append(Data(repeating: 0, count: chunk.offset))
        }
        data.append(chunk.value.data)
        stringData = RedisBinaryValue(data: data)
        originalStringData = stringData
        stringTotalByteCount = chunk.totalByteCount
        isStringFullyLoaded = data.count >= chunk.totalByteCount
        stringValue = String(decoding: data, as: UTF8.self)
        stringEditingFormat = .text
        applyStringPresentation(stringTextPresentation)
        stringFormatError = nil
    }

    func mutationPlan() throws -> RedisKeyMutationPlan {
        guard let details else { throw RedisKeyEditError.unavailable }
        switch details.reference.type {
        case .string, .hash, .set, .sortedSet:
            break
        case .list where usesPagedCollection:
            break
        case .list, .stream, .module, .unknown, .none:
            if expirationWasModified(comparedWith: details) {
                break
            }
            throw RedisKeyEditError.unsupportedType(details.reference.type)
        }
        return try RedisKeyMutationPlan.make(
            details: details,
            stringValue: stringValue,
            rows: rows,
            expirationMode: expirationMode,
            ttlMillisecondsText: ttlMillisecondsText,
            expectedElementCount: collectionTotalCount,
            stringData: stringData,
            originalStringData: originalStringData
        )
    }

    private func hasRawChanges(comparedWith details: RedisKeyDetails) -> Bool {
        if expirationWasModified(comparedWith: details) { return true }
        switch details.reference.type {
        case .string:
            return stringData != originalStringData
                || stringFormatError != nil
        case .list, .hash, .set, .sortedSet:
            return rows.contains { $0.changeState != .unchanged }
        case .stream, .module, .unknown, .none:
            return false
        }
    }

    private func expirationWasModified(
        comparedWith details: RedisKeyDetails
    ) -> Bool {
        let originalMode: RedisKeyExpirationMode = details.ttlMilliseconds == nil
            ? .persistent
            : .expires
        let originalTTL = details.ttlMilliseconds.map(String.init) ?? ""
        return expirationMode != originalMode
            || (expirationMode == .expires
                && ttlMillisecondsText != originalTTL)
    }

    private func nearestRowID(
        to removedIndex: Int
    ) -> RedisKeyEditableRow.ID? {
        guard !rows.isEmpty else { return nil }
        return rows[min(removedIndex, rows.count - 1)].id
    }
}
