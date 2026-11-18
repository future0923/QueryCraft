import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class CloudSyncBilling {
    static let shared = CloudSyncBilling(
        mode: .configured(), store: CloudSyncStoreKit(),
        account: CloudSyncAccountClient.Configuration.configured().map { CloudSyncAccountClient(configuration: $0) },
        directGrant: {
            #if os(macOS)
            return await LicenseManager.shared.paidCloudSyncGrant()
            #else
            return nil
            #endif
        }
    )

    let mode: CloudSyncBillingMode
    private(set) var localGrants: [CloudSyncGrant] = []
    private(set) var accountGrants: [CloudSyncGrant] = []
    private(set) var trialExpiresAt: Date?
    /// Website plans the direct Mac may buy in-app; empty when unavailable.
    private(set) var websiteOptions: [CloudSyncPurchaseOption] = []
    /// True between opening a website checkout and seeing the paid grant.
    private(set) var awaitingWebsitePurchase = false
    var grants: [CloudSyncGrant] { localGrants + accountGrants }
    var accessSummary: CloudSyncAccessSummary {
        CloudSyncAccessSummary(grants: grants, trialExpiresAt: trialExpiresAt, now: now())
    }
    var accountConfigured: Bool { account != nil }
    @ObservationIgnored private var accountReceivedAt: (Date, ContinuousClock.Instant)?
    @ObservationIgnored private let account: (any CloudSyncAccountProviding)?
    @ObservationIgnored private var accountUpdates: Task<Void, Never>?
    private(set) var products: [CloudSyncPurchaseOption] = []
    private(set) var isWorking = false
    private(set) var message: String?
    @ObservationIgnored private let store: any CloudSyncPurchaseProviding
    @ObservationIgnored private let directGrant: @MainActor () async -> CloudSyncGrant?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pause: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var accountGeneration = 0
    @ObservationIgnored private var lastSuccessfulRefresh: ContinuousClock.Instant?

    init(mode: CloudSyncBillingMode, store: any CloudSyncPurchaseProviding,
         account: (any CloudSyncAccountProviding)? = nil,
         directGrant: @escaping @MainActor () async -> CloudSyncGrant? = { nil },
         now: @escaping @Sendable () -> Date = Date.init,
         pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.mode = mode
        self.pause = pause
        self.store = store
        self.account = account
        self.directGrant = directGrant
        self.now = now
    }

    isolated deinit { updates?.cancel(); accountUpdates?.cancel() }

    var hasAccess: Bool {
        if mode == .preview { return true }
        if localGrants.contains(where: { $0.allowsSync(at: now()) }) { return true }
        guard let (received, instant) = accountReceivedAt else { return false }
        let elapsed = instant.duration(to: .now).components
        let effectiveNow = received.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        return accountGrants.contains { $0.allowsSync(at: effectiveNow) }
    }

    func accountChanged() {
        accountGeneration += 1
        revision += 1
        accountGrants = []
        trialExpiresAt = nil
        accountReceivedAt = nil
        lastSuccessfulRefresh = nil
        awaitingWebsitePurchase = false
        message = CloudSyncCopy.current.accountChanged
    }

    func checkAccess() async -> Bool {
        // A single sync checks several phases. Avoid repeatedly contacting Apple
        // for the same short lease; explicit refresh/restore always revalidates.
        if hasAccess, let lastSuccessfulRefresh,
           lastSuccessfulRefresh.duration(to: .now) < .seconds(60) { return true }
        await refresh()
        return hasAccess
    }

    func refresh() async {
        if account != nil, accountUpdates == nil {
            let notifications = NotificationCenter.default.notifications(named: .CKAccountChanged)
            accountUpdates = Task { [weak self] in
                for await _ in notifications {
                    guard !Task.isCancelled else { return }
                    self?.accountChanged()
                }
            }
        }
        if mode == .appStore, updates == nil {
            updates = store.observeChanges { [weak self] in await self?.refresh() }
        }
        revision += 1
        let current = revision
        let fetched: [CloudSyncGrant]
        switch mode {
        case .appStore: fetched = await store.currentGrants()
        case .direct: fetched = await directGrant().map { [$0] } ?? []
        case .preview, .unavailable: fetched = []
        }
        var snapshot: CloudSyncAccountSnapshot?
        var accountError: Error?
        if mode != .preview, mode != .unavailable, let account {
            do {
                let proofs = mode == .appStore ? await store.signedTransactions() : []
                if proofs.isEmpty {
                    snapshot = try await account.access(startTrial: false, link: nil)
                } else {
                    snapshot = try await account.linkAppStore(proofs)
                }
            }
            catch { accountError = error }
        }
        guard current == revision, !Task.isCancelled else { return }
        localGrants = fetched
        apply(snapshot)
        lastSuccessfulRefresh = accountError == nil ? .now : nil
        if accountError != nil {
            message = fetched.contains { $0.source == .appStore && $0.allowsSync(at: now()) }
                ? CloudSyncCopy.current.purchaseBridgePending : CloudSyncCopy.current.accountAccessFailed
        } else if message == CloudSyncCopy.current.accountAccessFailed || message == CloudSyncCopy.current.purchaseBridgePending { message = nil }

    }

    private func apply(_ snapshot: CloudSyncAccountSnapshot?) {
        accountGrants = snapshot?.grants ?? []
        trialExpiresAt = snapshot?.trialExpiresAt
        accountReceivedAt = snapshot == nil ? nil : (.now, .now)
        // Keep the last known price list through a failed check so the plan
        // rows do not disappear and reappear around a retry.
        if let snapshot, mode == .direct {
            websiteOptions = CloudSyncPlan.allCases.compactMap { plan in
                snapshot.websitePrices[plan].map { CloudSyncPurchaseOption(plan: plan, displayPrice: $0, price: Self.amount($0)) }
            }
        }
        if awaitingWebsitePurchase, accessSummary.isPaid {
            awaitingWebsitePurchase = false
            message = nil
        }
    }

    /// Numeric part of a display price such as "¥16.9", used only for savings.
    static func amount(_ price: String) -> Decimal? {
        let digits = price.filter { $0.isNumber || $0 == "." }
        return digits.isEmpty ? nil : Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX"))
    }

    func startTrial() async { await updateAccount(startTrial: true, link: nil) }

    #if os(macOS)
    func linkCurrentLicense() async {
        guard !isWorking else { return }
        do {
            let link = try await LicenseManager.shared.cloudSyncLicenseLink()
            await updateAccount(startTrial: false, link: link)
        } catch { message = CloudSyncCopy.current.noLicenseToLink }
    }
    #endif

    private func updateAccount(startTrial: Bool, link: CloudSyncLicenseLink?) async {
        guard mode == .direct || mode == .appStore, let account, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        revision += 1
        let current = revision
        message = nil
        do {
            let snapshot = try await account.access(startTrial: startTrial, link: link)
            guard current == revision, !Task.isCancelled else { return }
            apply(snapshot)
            lastSuccessfulRefresh = .now
            if startTrial, snapshot.grants.isEmpty { message = CloudSyncCopy.current.trialEnded }
            else if link != nil { message = CloudSyncCopy.current.licenseLinked }
        } catch {
            guard current == revision else { return }
            apply(nil)
            if error is CancellationError { return }
            message = (error as? CloudSyncAccountError) == .accountConflict
                ? CloudSyncCopy.current.licenseAccountConflict : CloudSyncCopy.current.accountAccessFailed
        }
    }

    func loadProducts() async {
        guard mode == .appStore, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            products = try await store.products()
            message = products.isEmpty ? CloudSyncCopy.current.purchaseUnavailable : nil
        } catch is CancellationError {
            return
        } catch { message = CloudSyncCopy.current.purchaseFailed }
        await refresh()
    }

    func purchase(_ plan: CloudSyncPlan) async {
        guard mode == .appStore, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            guard let account else { throw CloudSyncAccountError.unavailable }
            let generation = accountGeneration
            let prepared = try await account.preparePurchase()
            guard generation == accountGeneration, let token = prepared.appAccountToken else {
                throw CloudSyncAccountError.identityChanged
            }
            try Task.checkCancellation()
            let outcome = try await store.purchase(plan, accountToken: token)
            guard generation == accountGeneration else {
                message = CloudSyncCopy.current.accountChanged
                return
            }
            switch outcome {
            case .completed: await refresh()
            case .pending: message = CloudSyncCopy.current.purchasePending
            case .cancelled: break
            }
        } catch is CancellationError {
            return
        } catch { message = CloudSyncCopy.current.purchaseFailed }
    }

    /// Only called from the user's Restore Purchases action; never prompts
    /// for an App Store sign-in on an automatic sync or app launch.
    func restore() async {
        guard mode == .appStore, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            try await store.restore()
            await refresh()
            if !hasAccess, message == nil { message = CloudSyncCopy.current.noPurchases }
        } catch is CancellationError {
            return
        } catch { message = CloudSyncCopy.current.purchaseFailed }
    }

    /// Website download only: creates a checkout bound to the current iCloud
    /// account. The caller opens the returned page in the browser; the paid
    /// license unlocks this account without entering a key.
    func websiteCheckout(_ plan: CloudSyncPlan) async -> URL? {
        guard mode == .direct, let account, !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        message = nil
        let generation = accountGeneration
        do {
            let snapshot = try await account.checkout(plan)
            guard generation == accountGeneration, !Task.isCancelled, let url = snapshot.checkoutURL else {
                if generation != accountGeneration { message = CloudSyncCopy.current.accountChanged }
                return nil
            }
            awaitingWebsitePurchase = true
            message = CloudSyncCopy.current.websiteCheckoutOpened
            return url
        } catch is CancellationError {
            return nil
        } catch {
            message = CloudSyncCopy.current.websiteCheckoutFailed
            return nil
        }
    }

    /// Called when the app becomes active after a website checkout. Payment
    /// confirmation arrives by webhook a few seconds later, so check a few
    /// times before leaving it to the manual "check" action.
    func resumeAfterWebsiteCheckout(attempts: Int = 5) async {
        guard awaitingWebsitePurchase else { return }
        for attempt in 0..<attempts {
            if attempt > 0 {
                do { try await pause(.seconds(3)) } catch { return }
            }
            guard awaitingWebsitePurchase else { return }
            await refresh()
            if accessSummary.isPaid { return }
        }
        if awaitingWebsitePurchase { message = CloudSyncCopy.current.websitePaymentPending }
    }

    #if os(macOS)
    func activateDirectLicense(_ key: String) async {
        guard mode == .direct, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            try await LicenseManager.shared.activate(licenseKey: key)
            await refresh()
        } catch { message = CloudSyncCopy.current.purchaseFailed }
    }
    #endif
}
