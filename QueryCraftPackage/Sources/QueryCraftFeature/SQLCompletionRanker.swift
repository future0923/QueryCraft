import Foundation

struct SQLCompletionCandidate {
    let label: String
    let insertionText: String
    let detail: String
    let kind: SQLCompletionItem.Kind
    let rankingGroup: Int
    let contextPriority: Int
    let cursorOffset: Int
    let allowsFuzzyMatch: Bool

    init(
        label: String,
        insertionText: String,
        detail: String,
        kind: SQLCompletionItem.Kind,
        rankingGroup: Int,
        contextPriority: Int,
        cursorOffset: Int,
        allowsFuzzyMatch: Bool = true
    ) {
        self.label = label
        self.insertionText = insertionText
        self.detail = detail
        self.kind = kind
        self.rankingGroup = rankingGroup
        self.contextPriority = contextPriority
        self.cursorOffset = cursorOffset
        self.allowsFuzzyMatch = allowsFuzzyMatch
    }
}

enum SQLCompletionRanker {
    static func rank(
        _ candidates: [SQLCompletionCandidate],
        prefix: String,
        replacementRange: SQLSourceRange,
        revision: SQLSourceRevision,
        limit: Int
    ) throws -> [SQLCompletionItem] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        var best = BoundedBestCandidates(limit: limit)
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard let match = CompletionLabelMatcher.match(
                label: candidate.label,
                query: prefix,
                allowsFuzzyMatch: candidate.allowsFuzzyMatch
            ) else { continue }
            let key = "\(candidate.kind):\(candidate.insertionText.lowercased())"
            guard seen.insert(key).inserted else { continue }
            best.insert(
                RankedCandidate(
                    candidate: candidate,
                    matchTier: match.tier,
                    score: candidate.contextPriority + match.score,
                    sequence: index
                )
            )
        }
        try Task.checkCancellation()
        return best.sorted().map { ranked in
            SQLCompletionItem(
                label: ranked.candidate.label,
                insertionText: ranked.candidate.insertionText,
                detail: ranked.candidate.detail,
                kind: ranked.candidate.kind,
                replacementRange: replacementRange,
                sourceRevision: revision,
                cursorOffset: ranked.candidate.cursorOffset
            )
        }
    }

    private struct RankedCandidate {
        let candidate: SQLCompletionCandidate
        let matchTier: Int
        let score: Int
        let sequence: Int
    }

    private struct BoundedBestCandidates {
        let limit: Int
        var heap: [RankedCandidate] = []

        mutating func insert(_ candidate: RankedCandidate) {
            if heap.count < limit {
                heap.append(candidate)
                siftUp(from: heap.count - 1)
            } else if Self.isBetter(candidate, than: heap[0]) {
                heap[0] = candidate
                siftDown(from: 0)
            }
        }

        func sorted() -> [RankedCandidate] {
            heap.sorted { Self.isBetter($0, than: $1) }
        }

        private mutating func siftUp(from startIndex: Int) {
            var child = startIndex
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.isBetter(heap[parent], than: heap[child]) else { return }
                heap.swapAt(parent, child)
                child = parent
            }
        }

        private mutating func siftDown(from startIndex: Int) {
            var parent = startIndex
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { return }
                let right = left + 1
                var worseChild = left
                if right < heap.count,
                   Self.isBetter(heap[left], than: heap[right])
                {
                    worseChild = right
                }
                guard Self.isBetter(heap[parent], than: heap[worseChild]) else { return }
                heap.swapAt(parent, worseChild)
                parent = worseChild
            }
        }

        private static func isBetter(
            _ lhs: RankedCandidate,
            than rhs: RankedCandidate
        ) -> Bool {
            if lhs.candidate.rankingGroup != rhs.candidate.rankingGroup {
                return lhs.candidate.rankingGroup < rhs.candidate.rankingGroup
            }
            if lhs.matchTier != rhs.matchTier {
                return lhs.matchTier < rhs.matchTier
            }
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            let labelOrder = lhs.candidate.label.localizedStandardCompare(
                rhs.candidate.label
            )
            if labelOrder != .orderedSame {
                return labelOrder == .orderedAscending
            }
            return lhs.sequence < rhs.sequence
        }
    }
}
