import UIKit
import QueryCraftMobileCore

/// A committed page, separate from its data revision: refresh preserves the
/// viewport; changing filters/order/page starts at row one, like the Mac grid.
struct MobileGridPageContext: Hashable, Sendable {
    let offset: Int
    let limit: Int
    let sortColumn: String?
    let ascending: Bool
    let filter: WorkspaceDatabaseDataFilter

    init(page: MobileTableSnapshot) {
        offset = page.offset; limit = page.pageSize; sortColumn = page.sortColumn
        ascending = page.ascending; filter = page.filter
    }
}

/// Non-observable scroll state avoids invalidating SwiftUI on each scroll frame.
@MainActor final class MobileGridViewport {
    var context = ""
    var columns: [String] = []
    var metadata: [WorkspaceDatabaseDataColumn] = []
    var pageContext: MobileGridPageContext?
    var offset = CGPoint.zero
    var selection: IndexPath?
    var widths: [CGFloat] = []
    var activeOwner: UUID?
    let timestampDisplay = MobileGridTimestampDisplay()
}

/// Lock one axis for the entire pan/deceleration, including initially diagonal pans.
struct MobileGridAxisLock {
    enum Axis { case horizontal, vertical }
    private(set) var axis: Axis?
    private(set) var isTracking = false
    private var origin = CGPoint.zero

    mutating func begin(at offset: CGPoint, translation: CGPoint = .zero, velocity: CGPoint = .zero) {
        origin = offset; axis = nil; isTracking = true
        resolve(translation: translation, velocity: velocity)
    }

    mutating func constrain(_ offset: CGPoint, translation: CGPoint = .zero, velocity: CGPoint = .zero) -> CGPoint {
        guard isTracking else { return offset }
        resolve(translation: translation, velocity: velocity)
        switch axis {
        case .horizontal: return CGPoint(x: offset.x, y: origin.y)
        case .vertical: return CGPoint(x: origin.x, y: offset.y)
        case nil: return origin
        }
    }

    mutating func end() { axis = nil; isTracking = false }

    private mutating func resolve(translation: CGPoint, velocity: CGPoint) {
        guard axis == nil else { return }
        let sample: CGPoint
        if max(abs(translation.x), abs(translation.y)) >= 3 { sample = translation }
        else if max(abs(velocity.x), abs(velocity.y)) >= 20 { sample = velocity }
        else { return }
        axis = abs(sample.x) >= abs(sample.y) ? .horizontal : .vertical
    }
}
