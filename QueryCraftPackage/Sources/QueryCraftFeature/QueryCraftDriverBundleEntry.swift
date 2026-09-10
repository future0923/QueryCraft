import Foundation

/// The versioned activation boundary shared by QueryCraft and downloaded drivers.
@MainActor
public protocol QueryCraftDriverBundleEntry: AnyObject, Sendable {
    init()

    func activate() async throws
}
