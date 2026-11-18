import Foundation
import StoreKit
import StoreKitTest
import Testing
#if os(macOS)
@testable import QueryCraftPurchaseTestHost
#else
@testable import QueryCraftMobileProof
#endif

/// Real Apple StoreKit transactions in a local test environment. No account,
/// payment, production server, or CloudKit access is involved.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_STOREKIT_TESTS"] == "1", "Run the QueryCraftSyncPurchases scheme"))
@MainActor
struct CloudSyncStoreKitTests {
    private func makeSession() throws -> SKTestSession {
        let bundle = Bundle(for: StoreKitTestBundle.self)
        let url = try #require(bundle.url(forResource: "QueryCraftSync", withExtension: "storekit", subdirectory: "StoreKitFixtures"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    @Test(arguments: CloudSyncPlan.allCases)
    func verifiedPurchaseRestoreAndRefund(plan: CloudSyncPlan) async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = CloudSyncStoreKit()
        let updates = store.observeChanges {}
        defer { updates.cancel() }
        let products = try await store.products()
        try #require(Set(products.map(\.plan)) == Set(CloudSyncPlan.allCases))
        let expectedPrices: [CloudSyncPlan: Decimal] = [.monthly: 3.8, .halfYear: 16.8, .annual: 26.8, .perpetual: 39.9]
        for product in products {
            #expect(product.price == expectedPrices[product.plan])
            #expect(!product.displayPrice.isEmpty)
        }
        #expect(await store.currentGrants().isEmpty)
        let token = UUID()
        try #require(try await store.purchase(plan, accountToken: token) == .completed)
        let verification = try #require(await Transaction.latest(for: plan.productID))
        let transaction = try verification.payloadValue
        #expect(transaction.appAccountToken == token)
        #expect(transaction.environment == .xcode)
        #expect(await store.currentGrants().contains { $0.plan == plan && $0.allowsSync(at: .now) })
        #expect(await store.signedTransactions().count == 1)

        let reopened = CloudSyncStoreKit()
        try await reopened.restore()
        let grant = try #require(await reopened.currentGrants().first { $0.plan == plan })
        #expect(grant.allowsSync(at: .now))
        #expect((grant.expiresAt == nil) == (plan == .perpetual))
        try session.refundTransaction(identifier: UInt(transaction.id))
        try await waitForRevocation(in: reopened)
    }

    @Test(arguments: [CloudSyncPlan.monthly, .halfYear, .annual])
    func subscriptionRenewalAndExpiry(plan: CloudSyncPlan) async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = CloudSyncStoreKit()
        let updates = store.observeChanges {}
        defer { updates.cancel() }
        session.timeRate = .oneRenewalEveryTenSeconds
        // Inject the initial Apple transaction without purchase UI time counting
        // against the accelerated renewal period. Product.purchase is covered
        // separately for every plan above.
        let first = try await session.buyProduct(identifier: plan.productID, options: [.appAccountToken(UUID())])
        // StoreKit renews asynchronously. Wait for the observable entitlement,
        // with a deadline, rather than assuming a fixed scheduling delay.
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        var renewed = false
        while ContinuousClock.now < deadline {
            if let result = await Transaction.latest(for: plan.productID),
               case let .verified(transaction) = result,
               transaction.id != first.id,
               transaction.originalID == first.originalID,
               await store.currentGrants().contains(where: { $0.plan == plan && $0.allowsSync(at: .now) }) {
                renewed = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(renewed, "Apple StoreKit should issue a renewed entitlement")
        session.timeRate = .realTime
        try session.expireSubscription(productIdentifier: plan.productID)
        try await waitForRevocation(in: store)
    }

    private func waitForRevocation(in store: CloudSyncStoreKit) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            if await store.currentGrants().allSatisfy({ !$0.allowsSync(at: .now) }),
               await store.signedTransactions().isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Revoked or expired purchase must stop granting sync and providing purchase proofs")
    }
}

private final class StoreKitTestBundle: NSObject {}
