import AppKit
import SwiftUI

/// Counts completed requests, never the request that is about to start.
struct SchemaComparisonLoadProgress: Equatable, Sendable {
    var completed: Int = 0
    var total: Int? = nil
    var objectName = ""

    mutating func accept(_ next: Self) {
        guard let total = next.total, total >= 0 else { return }
        if let previous = self.total, previous != total { return }
        guard next.completed >= completed else { return }
        self.total = total
        completed = max(completed, min(total, max(0, next.completed)))
        objectName = next.objectName
    }
}

struct SchemaComparisonProgress: Equatable, Sendable {
    enum Side: Sendable { case source, target }
    var source = SchemaComparisonLoadProgress()
    var target = SchemaComparisonLoadProgress()
    var isComparing = false

    var completed: Int { source.completed + target.completed }
    var total: Int? {
        guard let sourceTotal = source.total, let targetTotal = target.total else { return nil }
        return sourceTotal + targetTotal
    }
    var fraction: Double? {
        guard let total else { return nil }
        return total == 0 ? 1 : Double(completed) / Double(total)
    }
    mutating func accept(_ event: SchemaComparisonLoadProgress, side: Side) {
        switch side {
        case .source: source.accept(event)
        case .target: target.accept(event)
        }
    }
}

/// Keep one native indicator alive while counts and object names change.
struct SchemaComparisonProgressIndicator: NSViewRepresentable {
    let fraction: Double?

    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.isIndeterminate = false
        indicator.isDisplayedWhenStopped = true
        indicator.setAccessibilityIdentifier("schemaComparisonReadingProgress")
        return indicator
    }

    func updateNSView(_ indicator: NSProgressIndicator, context: Context) {
        indicator.doubleValue = 100 * min(1, max(0, fraction ?? 0))
    }
}
