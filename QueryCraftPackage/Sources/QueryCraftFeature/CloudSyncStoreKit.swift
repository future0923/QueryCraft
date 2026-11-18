import Foundation
import StoreKit

/// StoreKit is the verification boundary. Unverified transactions, unknown
/// products, consumables, upgrades and revoked purchases never unlock sync.
@MainActor
final class CloudSyncStoreKit: CloudSyncPurchaseProviding {
    private var catalog: [String: Product] = [:]

    func products() async throws -> [CloudSyncPurchaseOption] {
        let products = try await Product.products(for: CloudSyncPlan.allCases.map(\.productID))
        catalog = Dictionary(uniqueKeysWithValues: products.filter(Self.isSupported).map { ($0.id, $0) })
        return CloudSyncPlan.allCases.compactMap { plan in
            catalog[plan.productID].map { CloudSyncPurchaseOption(plan: plan, displayPrice: $0.displayPrice, price: $0.price) }
        }
    }

    func currentGrants() async -> [CloudSyncGrant] {
        var grants: [CloudSyncGrant] = []
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  let plan = CloudSyncPlan(productID: transaction.productID),
                  transaction.revocationDate == nil, !transaction.isUpgraded
            else { continue }
            if plan == .perpetual {
                guard transaction.productType == .nonConsumable else { continue }
                grants.append(.init(source: .appStore, plan: plan, expiresAt: nil))
            } else if transaction.productType == .autoRenewable {
                // currentEntitlements includes grace periods. Check verified
                // renewal info instead of treating an expired transaction as
                // perpetual or cutting off Apple's billing grace period.
                var expiry = transaction.expirationDate
                if let group = transaction.subscriptionGroupID,
                   let statuses = try? await Product.SubscriptionInfo.status(for: group) {
                    for status in statuses where status.state == .inGracePeriod {
                        guard case let .verified(current) = status.transaction,
                              current.id == transaction.id,
                              case let .verified(renewal) = status.renewalInfo,
                              let grace = renewal.gracePeriodExpirationDate else { continue }
                        expiry = max(expiry ?? .distantPast, grace)
                    }
                }
                guard let expiry else { continue }
                grants.append(.init(source: .appStore, plan: plan, expiresAt: expiry))
            }
        }
        return grants
    }

    func purchase(_ plan: CloudSyncPlan, accountToken: UUID) async throws -> CloudSyncPurchaseOutcome {
        if catalog[plan.productID] == nil { _ = try await products() }
        guard let product = catalog[plan.productID], Self.isSupported(product) else {
            throw CloudSyncPurchaseError.unavailable
        }
        switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
        case let .success(result):
            guard case let .verified(transaction) = result,
                  transaction.productID == plan.productID,
                  transaction.revocationDate == nil, !transaction.isUpgraded
            else { throw CloudSyncPurchaseError.verificationFailed }
            // Entitlements are reconstructed from Apple's persistent verified
            // transactions, so finishing is safe across process termination.
            await transaction.finish()
            return .completed
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw CloudSyncPurchaseError.failed
        }
    }

    func signedTransactions() async -> [String] {
        var proofs: [String] = []
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  let plan = CloudSyncPlan(productID: transaction.productID),
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  transaction.productType == (plan == .perpetual ? .nonConsumable : .autoRenewable)
            else { continue }
            proofs.append(result.jwsRepresentation)
            if proofs.count == 8 { break }
        }
        return proofs
    }

    func restore() async throws { try await AppStore.sync() }

    func observeChanges(_ changed: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case let .verified(transaction) = result,
                      CloudSyncPlan(productID: transaction.productID) != nil else { continue }
                await changed()
                await transaction.finish()
            }
        }
    }

    private static func isSupported(_ product: Product) -> Bool {
        guard let plan = CloudSyncPlan(productID: product.id) else { return false }
        return product.type == (plan == .perpetual ? .nonConsumable : .autoRenewable)
    }
}
