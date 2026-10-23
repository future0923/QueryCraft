import Foundation

struct CompletionLabelMatch: Equatable, Sendable {
    let tier: Int
    let score: Int
}

enum CompletionLabelMatcher {
    private static let fuzzySeparators: Set<Character> = ["_", ".", "-", " "]

    /// Shared catalog filtering and ranking, including stable order for equal matches.
    static func matching<Item>(_ items: [Item], query: String, label: KeyPath<Item, String>) -> [Item] {
        guard !query.isEmpty else { return items }
        return items.enumerated().compactMap { index, item in
            match(label: item[keyPath: label], query: query).map {
                (item: item, match: $0, index: index)
            }
        }.sorted {
            if $0.match.tier != $1.match.tier { return $0.match.tier < $1.match.tier }
            if $0.match.score != $1.match.score { return $0.match.score < $1.match.score }
            return $0.index < $1.index
        }.map(\.item)
    }

    static func match(
        label: String,
        query: String,
        allowsFuzzyMatch: Bool = true
    ) -> CompletionLabelMatch? {
        let normalizedLabel = label.lowercased()
        let normalizedQuery = query.lowercased()
        if normalizedQuery.isEmpty {
            return CompletionLabelMatch(tier: 0, score: 300)
        }
        if normalizedLabel == normalizedQuery {
            return CompletionLabelMatch(tier: 0, score: 0)
        }
        if normalizedLabel.hasPrefix(normalizedQuery) {
            return CompletionLabelMatch(tier: 1, score: 100)
        }
        if normalizedLabel.contains(normalizedQuery) {
            return CompletionLabelMatch(tier: 2, score: 200)
        }
        guard allowsFuzzyMatch,
              let score = fuzzyMatchScore(
                query: Array(normalizedQuery),
                label: normalizedLabel
              )
        else { return nil }
        return CompletionLabelMatch(tier: 3, score: score)
    }

    private static func fuzzyMatchScore(
        query: [Character],
        label: String
    ) -> Int? {
        let labelCharacters = Array(label)
        guard !query.isEmpty else { return nil }

        var positions: [Int] = []
        positions.reserveCapacity(query.count)
        var searchStart = 0
        for character in query {
            guard searchStart < labelCharacters.count,
                  let match = labelCharacters[searchStart...]
                    .firstIndex(of: character)
            else { return nil }
            positions.append(match)
            searchStart = match + 1
        }

        var score = 340 + positions[0] * 2
        for (index, position) in positions.enumerated() {
            let isBoundary = position == 0
                || fuzzySeparators.contains(labelCharacters[position - 1])
            if isBoundary { score -= 10 }
            guard index > 0 else { continue }
            let gap = position - positions[index - 1] - 1
            score += min(gap, 20)
            if gap == 0 { score -= 3 }
        }
        score += max(0, labelCharacters.count - query.count) / 8
        return max(300, score)
    }
}
