import CryptoKit
import Foundation
import GRDB
import Testing
#if os(macOS)
@testable import QueryCraftFeature
#else
@testable import QueryCraftMobileProof
#endif

@MainActor
struct CloudSyncBillingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func purchaseRequiresAccountPreflightAndPassesStableToken() async {
        let store = PurchaseFixture()
        let account = BridgeFixture()
        let billing = CloudSyncBilling(mode: .appStore, store: store, account: account)
        await account.setFail(true)
        await billing.purchase(.monthly)
        #expect(store.purchases == 0)
        await account.setFail(false)
        await billing.purchase(.monthly)
        #expect(store.lastToken == account.token)
    }

    @Test func failedBridgeKeepsLocalPurchaseAndRestoreRetries() async {
        let store = PurchaseFixture()
        store.proofs = ["verified-fixture-jws"]
        store.grants = [.init(source: .appStore, plan: .perpetual, expiresAt: nil)]
        let account = BridgeFixture()
        await account.setFail(true)
        let billing = CloudSyncBilling(mode: .appStore, store: store, account: account)
        await billing.refresh()
        #expect(billing.hasAccess)
        #expect(billing.accountGrants.isEmpty)
        #expect(billing.message == CloudSyncCopy.current.purchaseBridgePending)
        await account.setFail(false)
        await billing.restore()
        #expect(billing.accountGrants.count == 1)
        #expect(await account.proofs == store.proofs)
        #expect(billing.message == nil)
    }

    @Test func accountSwitchDuringPreflightNeverOpensPaymentSheet() async {
        let entered = AsyncTestEvent()
        let release = AsyncTestEvent()
        let account = BridgeFixture(beforePrepare: { await entered.signal(); await release.wait() })
        let store = PurchaseFixture()
        let billing = CloudSyncBilling(mode: .appStore, store: store, account: account)
        let purchase = Task { await billing.purchase(.monthly) }
        await entered.wait()
        billing.accountChanged()
        await release.signal()
        await purchase.value
        #expect(store.purchases == 0)
        #expect(!billing.hasAccess)
    }

    @Test func directMacReadsAppStoreAccountGrantWithoutStoreKit() async {
        let store = PurchaseFixture()
        let billing = CloudSyncBilling(mode: .direct, store: store, account: BridgeFixture())
        await billing.refresh()
        #expect(billing.hasAccess)
        #expect(billing.accountGrants.first?.source == .appStore)
        #expect(store.reads == 0)
        #expect(store.purchases == 0)
    }

    @Test func accountTrialIsExplicitAndSwitchClearsIt() async {
        let account = AccountFixture()
        let billing = CloudSyncBilling(mode: .appStore, store: PurchaseFixture(), account: account)
        await billing.refresh()
        #expect(!billing.hasAccess)
        #expect(await account.starts == 0)
        await billing.startTrial()
        #expect(billing.hasAccess)
        #expect(await account.starts == 1)
        #expect(billing.trialExpiresAt != nil)
        billing.accountChanged()
        #expect(!billing.hasAccess)
        #expect(billing.trialExpiresAt == nil)
        await account.fail()
        await billing.refresh()
        #expect(!billing.hasAccess)
        #expect(billing.message == CloudSyncCopy.current.accountAccessFailed)
    }

    @Test func accountSwitchRejectsLateAuthorizationResponse() async {
        let account = DelayedAccountFixture()
        let billing = CloudSyncBilling(mode: .appStore, store: PurchaseFixture(), account: account)
        let refresh = Task { await billing.refresh() }
        await account.waitUntilRequested()
        billing.accountChanged()
        await account.complete()
        await refresh.value
        #expect(!billing.hasAccess)
        #expect(billing.accountGrants.isEmpty)
    }

    @Test func signedAccountResponseRejectsReplayOtherAccountsAndTampering() throws {
        let key = Curve25519.Signing.PrivateKey()
        let account = String(repeating: "a", count: 64)
        let nonce = String(repeating: "b", count: 64)
        let payload = CloudSyncAccountVerifier.Payload(version: 1, audience: "querycraft.cloud-sync",
            account: account, nonce: nonce, issuedAt: 1_800_000_000, validUntil: 1_800_000_600,
            trialStartedAt: 1_800_000_000, trialExpiresAt: 1_802_592_000,
            grants: [.init(source: "trial", plan: nil, expiresAt: 1_802_592_000)])
        let encoded = try JSONEncoder().encode(payload)
        let signature = try key.signature(for: encoded)
        let data = try JSONSerialization.data(withJSONObject: ["payload": encoded.base64EncodedString(), "signature": signature.base64EncodedString()])
        let result = try CloudSyncAccountVerifier.verify(data, publicKey: key.publicKey.rawRepresentation,
            account: account, nonce: nonce, elapsed: 4, now: now)
        #expect(result.grants.first?.expiresAt == now.addingTimeInterval(596))
        #expect(throws: (any Error).self) {
            try CloudSyncAccountVerifier.verify(data, publicKey: key.publicKey.rawRepresentation, account: "another-account", nonce: nonce)
        }
        #expect(throws: (any Error).self) {
            try CloudSyncAccountVerifier.verify(data, publicKey: key.publicKey.rawRepresentation, account: account, nonce: "old-response")
        }
        #expect(throws: (any Error).self) {
            try CloudSyncAccountVerifier.verify(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, account: account, nonce: nonce)
        }
        #expect(throws: (any Error).self) {
            try CloudSyncAccountVerifier.verify(data, publicKey: key.publicKey.rawRepresentation, account: account, nonce: nonce, elapsed: 121)
        }
    }

    @Test func signedResponseCarriesOnlyTrustedCheckoutAndAvailablePrices() throws {
        let key = Curve25519.Signing.PrivateKey()
        let account = String(repeating: "a", count: 64)
        let nonce = String(repeating: "b", count: 64)
        func verify(checkout: String?, prices: [String: String]?) throws -> CloudSyncAccountSnapshot {
            var payload = CloudSyncAccountVerifier.Payload(version: 1, audience: "querycraft.cloud-sync",
                account: account, nonce: nonce, issuedAt: 1_800_000_000, validUntil: 1_800_000_600,
                trialStartedAt: nil, trialExpiresAt: nil, grants: [])
            payload.checkoutURL = checkout
            payload.websitePrices = prices
            let encoded = try JSONEncoder().encode(payload)
            let signature = try key.signature(for: encoded)
            let data = try JSONSerialization.data(withJSONObject: ["payload": encoded.base64EncodedString(), "signature": signature.base64EncodedString()])
            return try CloudSyncAccountVerifier.verify(data, publicKey: key.publicKey.rawRepresentation,
                account: account, nonce: nonce, now: now)
        }
        let prices = ["monthly": "¥3.9", "annual": "¥26.9", "perpetual": "¥39.9"]
        let result = try verify(checkout: "https://pay.watcha.cn/ch_1", prices: prices)
        #expect(result.checkoutURL?.absoluteString == "https://pay.watcha.cn/ch_1")
        #expect(result.websitePrices[.halfYear] == nil)
        #expect(result.websitePrices.count == 3)
        for foreign in ["http://pay.watcha.cn/x", "https://pay.watcha.cn.evil.example/x", "https://evilalipay.com/x", "alipays://platformapi/other", "https://user@pay.watcha.cn/x", "https://pay.watcha.cn:443/x", "https://checkout.creem.io/x", "file:///tmp/x", "javascript:alert(1)"] {
            #expect(throws: (any Error).self) { try verify(checkout: foreign, prices: nil) }
        }
        #expect(try verify(checkout: "alipays://platformapi/startapp?appId=test", prices: nil).checkoutURL != nil)
        #expect(try verify(checkout: "https://openapi.alipay.com/gateway.do", prices: nil).checkoutURL != nil)
        var partial = prices
        partial["annual"] = nil
        #expect(try verify(checkout: nil, prices: partial).websitePrices.count == 2)
        #expect(try verify(checkout: nil, prices: nil).websitePrices.isEmpty)
    }

    @Test func directMacBuysOnWebsiteAndUnlocksAfterReturning() async {
        let account = WebsiteCheckoutFixture()
        let billing = CloudSyncBilling(mode: .direct, store: PurchaseFixture(), account: account, pause: { _ in })
        await billing.refresh()
        #expect(billing.websiteOptions.map(\.plan) == [.monthly, .annual, .perpetual])
        #expect(billing.websiteOptions.savingsPercent(for: .annual) == 42)
        #expect(!billing.hasAccess)

        let url = await billing.websiteCheckout(.annual)
        #expect(url?.host == "pay.watcha.cn")
        #expect(await account.plans == [.annual])
        #expect(billing.awaitingWebsitePurchase)
        #expect(billing.message == CloudSyncCopy.current.websiteCheckoutOpened)

        // Payment is confirmed by the provider a moment after the user returns.
        await account.payAfter(checks: 2)
        await billing.resumeAfterWebsiteCheckout()
        #expect(billing.hasAccess)
        #expect(billing.accessSummary.isPaid)
        #expect(!billing.awaitingWebsitePurchase)
        #expect(billing.message == nil)
    }

    @Test func unpaidWebsiteCheckoutStopsPollingWithGuidance() async {
        let account = WebsiteCheckoutFixture()
        let billing = CloudSyncBilling(mode: .direct, store: PurchaseFixture(), account: account, pause: { _ in })
        _ = await billing.websiteCheckout(.monthly)
        await billing.resumeAfterWebsiteCheckout(attempts: 3)
        #expect(await account.statusChecks == 3)
        #expect(!billing.hasAccess)
        #expect(billing.message == CloudSyncCopy.current.websitePaymentPending)

        billing.accountChanged()
        #expect(!billing.awaitingWebsitePurchase)
        await billing.resumeAfterWebsiteCheckout()
        #expect(await account.statusChecks == 3)
    }

    @Test func websiteCheckoutIsDirectOnlyAndFailsVisibly() async {
        let account = WebsiteCheckoutFixture()
        let appStore = CloudSyncBilling(mode: .appStore, store: PurchaseFixture(), account: account)
        #expect(await appStore.websiteCheckout(.monthly) == nil)
        await appStore.refresh()
        #expect(appStore.websiteOptions.isEmpty)
        #expect(await account.plans.isEmpty)

        await account.setFail(true)
        let direct = CloudSyncBilling(mode: .direct, store: PurchaseFixture(), account: account)
        #expect(await direct.websiteCheckout(.annual) == nil)
        #expect(!direct.awaitingWebsitePurchase)
        #expect(direct.message == CloudSyncCopy.current.websiteCheckoutFailed)
    }

    @Test func grantExpiryIsStrictAndOnlyPerpetualCanLackExpiry() {
        for source in [CloudSyncGrant.Source.appStore, .directLicense, .trial] {
            #expect(!CloudSyncGrant(source: source, plan: .annual, expiresAt: nil).allowsSync(at: now))
            #expect(!CloudSyncGrant(source: source, plan: .monthly, expiresAt: now).allowsSync(at: now))
            #expect(CloudSyncGrant(source: source, plan: .monthly, expiresAt: now.addingTimeInterval(1)).allowsSync(at: now))
        }
        #expect(CloudSyncGrant(source: .appStore, plan: .perpetual, expiresAt: nil).allowsSync(at: now))
        #expect(!CloudSyncGrant(source: .trial, plan: .perpetual, expiresAt: nil).allowsSync(at: now))
    }

    @Test func accountPurchaseExpiryDisplayDoesNotExtendAuthorizationLease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let account = String(repeating: "a", count: 64), nonce = String(repeating: "b", count: 64)
        let purchaseEnd: Int64 = 1_802_592_000
        for source in ["directLicense", "appStore"] {
            let payload = CloudSyncAccountVerifier.Payload(version: 1, audience: "querycraft.cloud-sync",
                account: account, nonce: nonce, issuedAt: 1_800_000_000, validUntil: 1_800_000_600,
                trialStartedAt: nil, trialExpiresAt: nil,
                grants: [.init(source: source, plan: "monthly", expiresAt: purchaseEnd)])
            let encoded = try JSONEncoder().encode(payload)
            let data = try JSONSerialization.data(withJSONObject: ["payload": encoded.base64EncodedString(),
                "signature": try key.signature(for: encoded).base64EncodedString()])
            let result = try CloudSyncAccountVerifier.verify(data, publicKey: key.publicKey.rawRepresentation,
                account: account, nonce: nonce, now: now)
            let grant = try #require(result.grants.first)
            let actualEnd = Date(timeIntervalSince1970: Double(purchaseEnd))
            #expect(grant.displayedExpiry == actualEnd)
            #expect(grant.allowsSync(at: now.addingTimeInterval(599)))
            #expect(!grant.allowsSync(at: now.addingTimeInterval(600)))
            let summary = CloudSyncAccessSummary(grants: result.grants, trialExpiresAt: nil, now: now)
            #expect(summary == (source == "directLicense" ? .website(until: actualEnd) : .subscribed(.monthly, until: actualEnd)))
        }
        let lifetime = CloudSyncGrant(source: .directLicense, plan: .perpetual, expiresAt: now.addingTimeInterval(600))
        #expect(CloudSyncAccessSummary(grants: [lifetime], trialExpiresAt: nil, now: now) == .website(until: nil))
        #expect(!lifetime.allowsSync(at: now.addingTimeInterval(600)))
    }

    @Test func savingsUseStorefrontPricesAndHideSmallOrMissingValues() {
        let options: [CloudSyncPurchaseOption] = [
            .init(plan: .monthly, displayPrice: "¥3.8", price: Decimal(string: "3.8")),
            .init(plan: .halfYear, displayPrice: "¥16.8", price: Decimal(string: "16.8")),
            .init(plan: .annual, displayPrice: "¥26.8", price: Decimal(string: "26.8")),
            .init(plan: .perpetual, displayPrice: "¥39.9", price: Decimal(string: "39.9")),
        ]
        #expect(options.savingsPercent(for: .annual) == 41)
        #expect(options.savingsPercent(for: .halfYear) == 26)
        #expect(options.savingsPercent(for: .monthly) == nil)
        #expect(options.savingsPercent(for: .perpetual) == nil)
        #expect(Array(options.dropFirst()).savingsPercent(for: .annual) == nil)
        let close: [CloudSyncPurchaseOption] = [
            .init(plan: .monthly, displayPrice: "1", price: 1), .init(plan: .annual, displayPrice: "12", price: 12),
        ]
        #expect(close.savingsPercent(for: .annual) == nil)
    }

    @Test func accessSummaryPrefersPaidAccessOverTrial() {
        let later = now.addingTimeInterval(86_400 * 10)
        let trial = CloudSyncGrant(source: .trial, plan: nil, expiresAt: later)
        let monthly = CloudSyncGrant(source: .appStore, plan: .monthly, expiresAt: later)
        typealias Summary = CloudSyncAccessSummary
        #expect(Summary(grants: [], trialExpiresAt: nil, now: now) == .trialAvailable)
        #expect(Summary(grants: [], trialExpiresAt: now, now: now) == .trialEnded)
        #expect(Summary(grants: [trial], trialExpiresAt: later, now: now) == .trial(until: later))
        #expect(Summary(grants: [trial, monthly], trialExpiresAt: later, now: now) == .subscribed(.monthly, until: later))
        #expect(Summary(grants: [monthly, .init(source: .appStore, plan: .perpetual, expiresAt: nil)],
                        trialExpiresAt: nil, now: now) == .lifetime)
        #expect(Summary(grants: [.init(source: .directLicense, plan: .perpetual, expiresAt: nil)],
                        trialExpiresAt: nil, now: now) == .website(until: nil))
        #expect(Summary(grants: [.init(source: .appStore, plan: .monthly, expiresAt: now)],
                        trialExpiresAt: now, now: now) == .trialEnded)
        #expect(CloudSyncAccessSummary.daysLeft(now.addingTimeInterval(86_400 * 2 + 1), now: now) == 3)
    }

    @Test func billingConfigurationFailsClosedUnlessPreviewIsExplicit() async {
        #expect(CloudSyncBillingMode.parse(nil) == .unavailable)
        #expect(CloudSyncBillingMode.parse("appstore") == .unavailable)
        let store = PurchaseFixture()
        let preview = CloudSyncBilling(mode: .preview, store: store)
        #expect(await preview.checkAccess())
        #expect(store.reads == 0)
        let missing = CloudSyncBilling(mode: .unavailable, store: store)
        #expect(!(await missing.checkAccess()))
        #expect(CloudSyncPlan(productID: "unrelated.product") == nil)
        #expect(Set(CloudSyncPlan.allCases.map(\.productID)).count == 4)
    }

    @Test func restoreDoesNotUnlockWithoutVerifiedGrants() async {
        let store = PurchaseFixture()
        let billing = CloudSyncBilling(mode: .appStore, store: store)
        await billing.restore()
        #expect(store.restores == 1)
        #expect(!billing.hasAccess)
        #expect(billing.message == CloudSyncCopy.current.noPurchases)
        store.grants = [.init(source: .appStore, plan: .perpetual, expiresAt: nil)]
        await billing.restore()
        #expect(billing.hasAccess)
        store.grants = [] // refund / revoked / account switch
        await store.changed?()
        #expect(!billing.hasAccess)
    }

    @Test func pendingCancelledAndFailedPurchasesDoNotUnlockOrLoseExistingAccess() async {
        let store = PurchaseFixture()
        let billing = CloudSyncBilling(mode: .appStore, store: store, account: AccountFixture())
        for outcome in [CloudSyncPurchaseOutcome.pending, .cancelled, .completed] {
            store.outcome = outcome
            await billing.purchase(.monthly)
            #expect(!billing.hasAccess, "A success callback alone is not a purchase proof")
            #expect(!billing.isWorking)
        }
        store.grants = [.init(source: .appStore, plan: .perpetual, expiresAt: nil)]
        await billing.refresh()
        store.fails = true
        await billing.purchase(.annual)
        #expect(billing.hasAccess)
        #expect(billing.message == CloudSyncCopy.current.purchaseFailed)
        #expect(!billing.isWorking)
    }

    @Test func expirationIsCheckedEvenWithoutTransactionUpdate() async {
        let clock = TestClock(now)
        let store = PurchaseFixture()
        store.grants = [.init(source: .appStore, plan: .monthly, expiresAt: now.addingTimeInterval(5))]
        let billing = CloudSyncBilling(mode: .appStore, store: store, now: { clock.value })
        #expect(await billing.checkAccess())
        clock.value = now.addingTimeInterval(5)
        #expect(!billing.hasAccess)
        #expect(!(await billing.checkAccess()))
    }

    @Test func directChannelNeverStartsAppStorePurchaseOrRestore() async {
        let store = PurchaseFixture()
        let billing = CloudSyncBilling(mode: .direct, store: store, directGrant: {
            .init(source: .directLicense, plan: .perpetual, expiresAt: nil)
        })
        #expect(await billing.checkAccess())
        await billing.purchase(.monthly)
        await billing.restore()
        #expect(store.purchases == 0)
        #expect(store.restores == 0)
        #expect(store.reads == 0)
    }

    @Test func copyMakesLocalFeaturesFreeInBothLanguages() {
        #expect(CloudSyncCopy(isChinese: true).freeFeatures.contains("永久免费"))
        #expect(CloudSyncCopy(isChinese: false).freeFeatures.contains("stay free"))
        #expect(CloudSyncCopy(isChinese: true).planName(.perpetual).contains("一次买断"))
        #expect(CloudSyncCopy(isChinese: false).purchasePending.contains("approval"))
    }

    @Test func olderEntitlementResponseCannotUndoRevocation() async {
        let store = PurchaseFixture()
        let entered = AsyncTestEvent()
        let release = AsyncTestEvent()
        store.grants = [.init(source: .appStore, plan: .perpetual, expiresAt: nil)]
        store.beforeReturn = { await entered.signal(); await release.wait() }
        let billing = CloudSyncBilling(mode: .appStore, store: store)
        let old = Task { await billing.refresh() }
        await entered.wait()
        store.beforeReturn = nil
        store.grants = []
        await billing.refresh()
        await release.signal()
        await old.value
        #expect(!billing.hasAccess)
    }

    @Test func disablingDuringAccountCheckCannotRestartSync() async throws {
        let fixture = try SyncFixture()
        let entered = AsyncTestEvent()
        let release = AsyncTestEvent()
        let controller = fixture.controller(accountAvailable: { _ in
            await entered.signal()
            await release.wait()
            return true
        })
        let enabling = Task { await controller.setEnabled(true) }
        await entered.wait()
        await controller.setEnabled(false)
        await release.signal()
        await enabling.value
        #expect(await fixture.engine.starts == 0)
        #expect(controller.status == .off)
        #expect(!controller.isEnabled)
        #expect(try fixture.metadata.outbox().count == 1)
    }

    @Test func deniedSyncDoesNotOpenCloudKitOrChangeTheOutbox() async throws {
        let fixture = try SyncFixture()
        fixture.allowed = false
        let controller = fixture.controller()
        await controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(controller.status == .unavailable(CloudSyncCopy.current.requiresPurchase))
        #expect(await fixture.engine.starts == 0)
        #expect(try fixture.metadata.outbox().count == 1)
    }

    @Test func expiryPausesAndRenewalResumesWithoutLosingOfflineChanges() async throws {
        let fixture = try SyncFixture()
        let controller = fixture.controller()
        await controller.setEnabled(true)
        #expect(await fixture.engine.starts == 1)
        fixture.allowed = false
        await controller.syncNow()
        #expect(controller.isEnabled, "Keep the user's intent so renewal can resume")
        #expect(await fixture.engine.stops == 1)
        #expect(await fixture.engine.syncs == 0)
        #expect(try fixture.metadata.outbox().count == 1)
        fixture.allowed = true
        await controller.syncNow()
        #expect(await fixture.engine.starts == 2)
        await controller.syncNow()
        #expect(await fixture.engine.syncs == 1)
        await controller.setEnabled(false)
        #expect(try fixture.metadata.outbox().count == 1)
        #expect(!controller.isEnabled)
    }

    #if os(macOS)
    @Test func disabledLegacyLicensingIsNotAPaidSyncGrant() {
        #expect(LicenseState.unrestrictedDevelopment.cloudSyncGrant == nil)
        #expect(LicenseState.restricted(.licenseExpired).cloudSyncGrant == nil)
        let expired = LicenseState.paid(plan: .annual, expiresAt: now, maximumActivations: 2)
        #expect(expired.cloudSyncGrant?.allowsSync(at: now) == false)
    }
    #endif
}

@MainActor private final class PurchaseFixture: CloudSyncPurchaseProviding {
    var grants: [CloudSyncGrant] = []
    var outcome = CloudSyncPurchaseOutcome.cancelled
    var fails = false
    var reads = 0
    var purchases = 0
    var lastToken: UUID?
    var proofs: [String] = []
    func signedTransactions() async -> [String] { proofs }
    var restores = 0
    var changed: (@MainActor () async -> Void)?
    var beforeReturn: (@MainActor () async -> Void)?
    func products() async throws -> [CloudSyncPurchaseOption] { [] }
    func currentGrants() async -> [CloudSyncGrant] {
        reads += 1
        let snapshot = grants
        await beforeReturn?()
        return snapshot
    }
    func purchase(_ plan: CloudSyncPlan, accountToken: UUID) async throws -> CloudSyncPurchaseOutcome {
        purchases += 1
        lastToken = accountToken
        if fails { throw CloudSyncPurchaseError.verificationFailed }
        return outcome
    }
    func restore() async throws { restores += 1 }
    func observeChanges(_ changed: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        self.changed = changed
        return Task {}
    }
}

// A lock-backed clock is shared by the Sendable clock closure and this test.
private final class TestClock: Sendable {
    private let storage: Synchronization.Mutex<Date>
    init(_ value: Date) { storage = .init(value) }
    var value: Date {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

import Synchronization

@MainActor private final class SyncFixture {
    var allowed = true
    let metadata: CloudSyncMetadataStore
    let engine = SyncEngineFixture()
    let suite = "CloudSyncBillingTests.\(UUID().uuidString)"
    init() throws {
        let writer = try DatabaseQueue()
        try writer.write { try CloudSyncMetadataStore.createTables(in: $0) }
        metadata = CloudSyncMetadataStore(writer: writer)
        try metadata.enqueue([.init(entity: .snippet, id: UUID())], deleted: true)
    }
    isolated deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
    func controller(accountAvailable: @escaping @Sendable (String) async throws -> Bool = { _ in true }) -> CloudSyncController {
        let metadata = metadata
        let engine = engine
        return CloudSyncController(
            containerIdentifier: "test.invalid", defaults: UserDefaults(suiteName: suite)!,
            makeMetadata: { metadata }, makeLocal: { _ in EmptySyncFixture() },
            hasAccess: { [weak self] in self?.allowed ?? false },
            accountAvailable: accountAvailable, makeEngine: { _ in engine }
        )
    }
}

private actor AsyncTestEvent {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor SyncEngineFixture: CloudSyncEngineRunning {
    var starts = 0
    var stops = 0
    var syncs = 0
    func start(initialMerge: Bool) { starts += 1 }
    func stop() { stops += 1 }
    func synchronize() { syncs += 1 }
}

private struct EmptySyncFixture: CloudSyncLocalStore {
    func value(for key: CloudSyncKey) async throws -> CloudSyncValue? { nil }
    func allKeys() async throws -> [CloudSyncKey] { [] }
    func apply(_ changes: [CloudSyncRemoteChange]) async throws -> [CloudSyncSavedQuery] { [] }
}

private actor AccountFixture: CloudSyncAccountProviding {
    func preparePurchase() async throws -> CloudSyncAccountSnapshot {
        .init(grants: [], trialExpiresAt: nil, appAccountToken: UUID())
    }
    var starts = 0
    var fails = false
    func fail() { fails = true }
    func access(startTrial: Bool, link: CloudSyncLicenseLink?) async throws -> CloudSyncAccountSnapshot {
        if fails { throw CloudSyncAccountError.unavailable }
        if startTrial { starts += 1 }
        return .init(grants: starts == 0 ? [] : [.init(source: .trial, plan: nil, expiresAt: .now.addingTimeInterval(600))],
                     trialExpiresAt: starts == 0 ? nil : .now.addingTimeInterval(30 * 86400))
    }
}

private actor DelayedAccountFixture: CloudSyncAccountProviding {
    var pending: CheckedContinuation<CloudSyncAccountSnapshot, Never>?
    var ready: CheckedContinuation<Void, Never>?
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func access(startTrial: Bool, link: CloudSyncLicenseLink?) async throws -> CloudSyncAccountSnapshot {
        await withCheckedContinuation {
            pending = $0
            ready?.resume(); ready = nil
        }
    }
    func complete() {
        pending?.resume(returning: .init(grants: [.init(source: .directLicense, plan: .perpetual, expiresAt: .now.addingTimeInterval(600))], trialExpiresAt: nil))
        pending = nil
    }
}

private actor BridgeFixture: CloudSyncAccountProviding {
    nonisolated let token = UUID()
    var fails = false
    var proofs: [String] = []
    let beforePrepare: (@Sendable () async -> Void)?
    init(beforePrepare: (@Sendable () async -> Void)? = nil) { self.beforePrepare = beforePrepare }
    func setFail(_ value: Bool) { fails = value }
    func preparePurchase() async throws -> CloudSyncAccountSnapshot {
        await beforePrepare?()
        if fails { throw CloudSyncAccountError.unavailable }
        return .init(grants: [], trialExpiresAt: nil, appAccountToken: token)
    }
    func access(startTrial: Bool, link: CloudSyncLicenseLink?) async throws -> CloudSyncAccountSnapshot {
        if fails { throw CloudSyncAccountError.unavailable }
        return .init(grants: [.init(source: .appStore, plan: .perpetual, expiresAt: .now.addingTimeInterval(600))], trialExpiresAt: nil)
    }
    func linkAppStore(_ signedTransactions: [String]) async throws -> CloudSyncAccountSnapshot {
        proofs = signedTransactions
        return try await access(startTrial: false, link: nil)
    }
}

private actor WebsiteCheckoutFixture: CloudSyncAccountProviding {
    var plans: [CloudSyncPlan] = []
    var statusChecks = 0
    var paidAfter: Int?
    var fails = false
    func setFail(_ value: Bool) { fails = value }
    func payAfter(checks: Int) { paidAfter = statusChecks + checks }
    private var prices: [CloudSyncPlan: String] {
        [.monthly: "¥3.9", .annual: "¥26.9", .perpetual: "¥39.9"]
    }
    func access(startTrial: Bool, link: CloudSyncLicenseLink?) async throws -> CloudSyncAccountSnapshot {
        if fails { throw CloudSyncAccountError.unavailable }
        statusChecks += 1
        let paid = paidAfter.map { statusChecks >= $0 } ?? false
        return .init(grants: paid ? [.init(source: .directLicense, plan: .halfYear, expiresAt: .now.addingTimeInterval(600))] : [],
                     trialExpiresAt: nil, websitePrices: prices)
    }
    func checkout(_ plan: CloudSyncPlan) async throws -> CloudSyncAccountSnapshot {
        if fails { throw CloudSyncAccountError.unavailable }
        plans.append(plan)
        return .init(grants: [], trialExpiresAt: nil, checkoutURL: URL(string: "https://pay.watcha.cn/ch_test"), websitePrices: prices)
    }
}
