import Foundation

/// Billing is independent of database access. Only a verified provider may
/// create grants; neither a UserDefaults flag nor an iCloud record is proof
/// of purchase.
enum CloudSyncPlan: String, CaseIterable, Sendable, Codable {
    case monthly, halfYear, annual, perpetual

    var productID: String { "io.github.future0923.QueryCraft.sync.\(rawValue)" }
    /// Plan identifier used by the license server.
    var serverName: String { self == .halfYear ? "half_year" : rawValue }

    init?(productID: String) {
        guard let plan = Self.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = plan
    }
}

struct CloudSyncGrant: Equatable, Sendable {
    enum Source: Equatable, Sendable { case appStore, directLicense, trial }
    let source: Source
    let plan: CloudSyncPlan?
    /// Authorization deadline; server grants must be refreshed after this lease.
    let expiresAt: Date?
    /// Original signed purchase expiry, for presentation only.
    var purchaseExpiresAt: Date? = nil

    var displayedExpiry: Date? {
        plan == .perpetual ? nil : (purchaseExpiresAt ?? expiresAt)
    }

    func allowsSync(at now: Date) -> Bool {
        if let expiresAt { return now < expiresAt }
        return plan == .perpetual && source != .trial
    }
}

enum CloudSyncBillingMode: String, Sendable {
    /// Explicitly retained for the current sync acceptance builds. An absent
    /// or misspelled configuration must never silently grant paid access.
    case preview, appStore, direct, unavailable

    static func configured(in bundle: Bundle = .main) -> Self {
        parse(bundle.object(forInfoDictionaryKey: "QCCloudSyncBillingMode") as? String)
    }

    static func parse(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .unavailable
    }
}

struct CloudSyncPurchaseOption: Equatable, Sendable, Identifiable {
    let plan: CloudSyncPlan
    let displayPrice: String
    var price: Decimal? = nil
    var id: String { plan.productID }
}

extension Array where Element == CloudSyncPurchaseOption {
    /// Whole-percent saving against paying monthly for the same period.
    func savingsPercent(for plan: CloudSyncPlan) -> Int? {
        let months: Decimal
        switch plan {
        case .halfYear: months = 6
        case .annual: months = 12
        case .monthly, .perpetual: return nil
        }
        guard let monthly = first(where: { $0.plan == .monthly })?.price,
              let price = first(where: { $0.plan == plan })?.price,
              monthly > 0, price > 0 else { return nil }
        let ratio = NSDecimalNumber(decimal: price / (monthly * months)).doubleValue
        let percent = Int(((1 - ratio) * 100).rounded(.down))
        return percent >= 5 ? percent : nil
    }
}

/// What the settings screen tells the user about their current sync access.
enum CloudSyncAccessSummary: Equatable, Sendable {
    case lifetime
    case subscribed(CloudSyncPlan, until: Date)
    case website(until: Date?)
    case trial(until: Date)
    case trialAvailable
    case trialEnded

    init(grants: [CloudSyncGrant], trialExpiresAt: Date?, now: Date) {
        let active = grants.filter { $0.allowsSync(at: now) }
        let paid = active.filter { $0.source != .trial }
        if paid.contains(where: { $0.plan == .perpetual && $0.source == .appStore }) {
            self = .lifetime
        } else if let website = paid.first(where: { $0.source == .directLicense }) {
            self = .website(until: website.displayedExpiry)
        } else if let subscription = paid.filter({ $0.plan != nil && $0.expiresAt != nil })
            .max(by: { $0.expiresAt! < $1.expiresAt! }) {
            self = .subscribed(subscription.plan!, until: subscription.displayedExpiry!)
        } else if let trial = active.first(where: { $0.source == .trial }), let until = trialExpiresAt ?? trial.displayedExpiry {
            self = .trial(until: until)
        } else if let trialExpiresAt, trialExpiresAt > now {
            self = .trial(until: trialExpiresAt)
        } else {
            self = trialExpiresAt == nil ? .trialAvailable : .trialEnded
        }
    }

    /// Whole days left, counting a partial day as one.
    static func daysLeft(_ until: Date, now: Date = .now) -> Int {
        max(1, Int((until.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    var isPaid: Bool {
        switch self {
        case .lifetime, .subscribed, .website: true
        case .trial, .trialAvailable, .trialEnded: false
        }
    }
}

enum CloudSyncPurchaseOutcome: Equatable, Sendable { case completed, pending, cancelled }

enum CloudSyncPurchaseError: Error, Equatable {
    case unavailable, verificationFailed, failed
}

@MainActor
protocol CloudSyncPurchaseProviding: AnyObject {
    func products() async throws -> [CloudSyncPurchaseOption]
    func currentGrants() async -> [CloudSyncGrant]
    func purchase(_ plan: CloudSyncPlan, accountToken: UUID) async throws -> CloudSyncPurchaseOutcome
    func signedTransactions() async -> [String]
    func restore() async throws
    func observeChanges(_ changed: @escaping @MainActor () async -> Void) -> Task<Void, Never>
}

extension CloudSyncPurchaseProviding {
    func signedTransactions() async -> [String] { [] }
}
