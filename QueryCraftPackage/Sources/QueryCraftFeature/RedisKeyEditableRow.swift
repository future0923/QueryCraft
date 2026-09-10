import Foundation

struct RedisKeyEditableRow: Identifiable, Equatable, Sendable {
    enum ChangeState: Equatable, Sendable {
        case unchanged
        case inserted
        case modified
        case deleted
    }

    let id: UUID
    let isNew: Bool
    let originalFirstValue: String
    let originalSecondValue: String
    let originalThirdValue: String
    let originalFirstData: RedisBinaryValue
    let originalSecondData: RedisBinaryValue
    let originalIndex: Int?
    let insertionEdge: RedisListInsertionEdge?
    let isBinaryReadOnly: Bool
    var firstValue: String
    var secondValue: String
    var thirdValue: String
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        isNew: Bool,
        firstValue: String,
        secondValue: String = "",
        thirdValue: String = "",
        originalFirstData: RedisBinaryValue? = nil,
        originalSecondData: RedisBinaryValue? = nil,
        originalIndex: Int? = nil,
        insertionEdge: RedisListInsertionEdge? = nil,
        isBinaryReadOnly: Bool = false,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.isNew = isNew
        originalFirstValue = firstValue
        originalSecondValue = secondValue
        originalThirdValue = thirdValue
        self.originalFirstData = originalFirstData
            ?? RedisBinaryValue(utf8: firstValue)
        self.originalSecondData = originalSecondData
            ?? RedisBinaryValue(utf8: secondValue)
        self.originalIndex = originalIndex
        self.insertionEdge = insertionEdge
        self.isBinaryReadOnly = isBinaryReadOnly
        self.firstValue = firstValue
        self.secondValue = secondValue
        self.thirdValue = thirdValue
        self.isDeleted = isDeleted
    }

    var changeState: ChangeState {
        if isDeleted { return .deleted }
        if isNew { return .inserted }
        if isFirstValueModified || isSecondValueModified || isThirdValueModified {
            return .modified
        }
        return .unchanged
    }

    var isFirstValueModified: Bool {
        !isNew && firstValue != originalFirstValue
    }

    var isSecondValueModified: Bool {
        !isNew && secondValue != originalSecondValue
    }

    var isThirdValueModified: Bool {
        !isNew && thirdValue != originalThirdValue
    }
}
