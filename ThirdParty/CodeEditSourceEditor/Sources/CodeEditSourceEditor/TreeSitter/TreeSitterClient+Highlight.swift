//
//  TreeSitterClient+Highlight.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/10/23.
//

import Foundation
import SwiftTreeSitter
import CodeEditLanguages

extension TreeSitterClient {
    func queryHighlightsForRange(range: NSRange) -> [HighlightRange] {
        guard let state = self.state else { return [] }

        var highlights: [HighlightRange] = []
        var injectedSet = IndexSet(integersIn: range)

        for layer in state.layers where layer.id != state.primaryLayer.id {
            // Query injected only if a layer's ranges intersects with `range`
            for layerRange in layer.ranges {
                if let rangeIntersection = range.intersection(layerRange) {
                    let queryResult = queryLayerHighlights(
                        layer: layer,
                        range: rangeIntersection
                    )

                    highlights.append(contentsOf: queryResult)
                    injectedSet.remove(integersIn: rangeIntersection)
                }
            }
        }

        // Query primary for any ranges that weren't used in the injected layers.
        for range in injectedSet.rangeView {
            let queryResult = queryLayerHighlights(
                layer: state.layers[0],
                range: NSRange(range)
            )
            highlights.append(contentsOf: queryResult)
        }

        return highlights
    }

    /// Queries the given language layer for any highlights.
    /// - Parameters:
    ///   - layer: The layer to query.
    ///   - range: The range to query for.
    /// - Returns: Any ranges to highlight.
    internal func queryLayerHighlights(
        layer: LanguageLayer,
        range: NSRange
    ) -> [HighlightRange] {
        guard let tree = layer.tree,
              let rootNode = tree.rootNode else {
            return []
        }

        // This needs to be on the main thread since we're going to use the `textProvider` in
        // the `highlightsFromCursor` method, which uses the textView's text storage.
        guard let queryCursor = layer.languageQuery?.execute(node: rootNode, in: tree) else {
            return []
        }
        queryCursor.setRange(range)
        queryCursor.matchLimit =  Constants.matchLimit

        return highlightsFromCursor(cursor: queryCursor, includedRange: range)
    }

    /// Resolves a query cursor to the highlight ranges it contains.
    /// **Must be called on the main thread**
    /// - Parameters:
    ///     - cursor: The cursor to resolve.
    ///     - includedRange: The range to include highlights from.
    /// - Returns: Any highlight ranges contained in the cursor.
    internal func highlightsFromCursor(
        cursor: QueryCursor,
        includedRange: NSRange
    ) -> [HighlightRange] {
        guard let readCallback else { return [] }
        // Resolve captures before handing them to StyledRangeContainer, which expects
        // disjoint runs. Emitting both a JSON string and its property capture made
        // the first one win accidentally; nested escapes also need their own runs.
        struct Candidate {
            let range: NSRange
            let originalLength: Int
            let priority: Int
            let capture: CaptureName
        }
        let candidates: [Candidate] = cursor.resolve(with: .init(textProvider: readCallback))
            .flatMap { $0.captures }
            .compactMap { capture in
                guard let name = CaptureName.fromString(capture.name),
                      let range = capture.range.intersection(includedRange), range.length > 0 else { return nil }
                return Candidate(range: range, originalLength: capture.range.length,
                                 priority: Int(capture.index), capture: name)
            }
        var starts: [Int: [Int]] = [:]
        var ends: [Int: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            starts[candidate.range.location, default: []].append(index)
            ends[NSMaxRange(candidate.range), default: []].append(index)
        }
        let boundaries = Set(starts.keys).union(ends.keys).sorted()
        var active: Set<Int> = []
        var result: [HighlightRange] = []
        for (index, boundary) in boundaries.enumerated() {
            for ended in ends[boundary] ?? [] { active.remove(ended) }
            for started in starts[boundary] ?? [] { active.insert(started) }
            guard index + 1 < boundaries.count,
                  let winner = active.min(by: { lhs, rhs in
                      let a = candidates[lhs], b = candidates[rhs]
                      if a.originalLength != b.originalLength { return a.originalLength < b.originalLength }
                      if a.priority != b.priority { return a.priority < b.priority }
                      return lhs < rhs
                  }) else { continue }
            let range = NSRange(location: boundary, length: boundaries[index + 1] - boundary)
            let capture = candidates[winner].capture
            if let last = result.last, last.capture == capture, NSMaxRange(last.range) == boundary {
                result[result.count - 1] = HighlightRange(
                    range: NSRange(location: last.range.location, length: last.range.length + range.length),
                    capture: capture
                )
            } else {
                result.append(HighlightRange(range: range, capture: capture))
            }
        }
        return result
    }
}
