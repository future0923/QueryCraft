import SwiftUI

/// Shared by the native Mac, iPhone and iPad settings forms. The sync switch
/// sits above this; here each access state gets its own content. Prices come
/// from the active App Store storefront; no plan is preselected or recommended.
struct CloudSyncPurchaseSection: View {
    let billing: CloudSyncBilling
    var onAccessChanged: () -> Void = {}
    @State private var action: Task<Void, Never>?
    @State private var licenseKey = ""
    @Environment(\.openURL) private var openURL
    private var copy: CloudSyncCopy { .current }

    #if os(iOS)
    private let rowHeight: CGFloat = 44
    #else
    private let rowHeight: CGFloat = 28
    #endif

    var body: some View {
        if billing.mode == .appStore || billing.mode == .direct {
            let summary = billing.accessSummary
            Group {
                Section {
                    accessRow(summary)
                    #if os(macOS)
                    if billing.mode == .direct { directLicenseRows(summary) }
                    #endif
                    if let message = billing.message {
                        messageRow(message)
                    }
                } header: {
                    HStack {
                        Text(copy.syncAccess)
                        Spacer()
                        ProgressView().controlSize(.small).opacity(billing.isWorking ? 1 : 0)
                            .accessibilityHidden(!billing.isWorking)
                    }
                } footer: {
                    if !summary.isPaid { Text(copy.freeFeatures) }
                    else if billing.mode == .appStore, summary != .lifetime { legalFooter }
                }
                .task {
                    if billing.mode == .appStore { await billing.loadProducts() } else { await billing.refresh() }
                }
                .onChange(of: billing.hasAccess) { _, _ in onAccessChanged() }
                .onDisappear { action?.cancel(); action = nil }

                if billing.mode == .appStore, !summary.isPaid {
                    Section {
                        // Keep the four rows in place while App Store prices load.
                        ForEach(CloudSyncPlan.allCases, id: \.self) { plan in
                            planRow(plan, options: billing.products) { await billing.purchase(plan) }
                        }
                    } header: {
                        Text(copy.chooseSyncPlan)
                    } footer: {
                        Text(copy.subscriptionShortTerms)
                    }

                    Section {
                        Button(copy.restorePurchases, systemImage: "arrow.counterclockwise") {
                            run { await billing.restore() }
                        }
                        .disabled(billing.isWorking)
                    } footer: {
                        legalFooter
                    }
                    .buttonStyle(.borderless)
                }

                #if os(macOS)
                if billing.mode == .direct, !summary.isPaid, !billing.websiteOptions.isEmpty {
                    Section {
                        ForEach(billing.websiteOptions.map(\.plan), id: \.self) { plan in
                            planRow(plan, options: billing.websiteOptions) { await buyOnWebsite(plan) }
                        }
                    } header: {
                        Text(copy.chooseSyncPlan)
                    } footer: {
                        Text(copy.websitePlanTerms)
                    }
                }
                #endif
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard billing.awaitingWebsitePurchase else { return }
                run { await billing.resumeAfterWebsiteCheckout() }
            }
            #endif
        }
    }

    #if os(macOS)
    private func buyOnWebsite(_ plan: CloudSyncPlan) async {
        if let url = await billing.websiteCheckout(plan) { openURL(url) }
    }
    #endif

    #if os(macOS)
    /// Website download: activate a license key, or share an activated one
    /// with the user's other devices through the current iCloud account.
    @ViewBuilder
    private func directLicenseRows(_ summary: CloudSyncAccessSummary) -> some View {
        switch summary {
        case .website:
            if billing.message != copy.licenseLinked {
                Button(copy.linkLicense, systemImage: "link.icloud") { run { await billing.linkCurrentLicense() } }
                    .buttonStyle(.borderless)
                    .disabled(billing.isWorking || !billing.accountConfigured)
            }
        case .lifetime, .subscribed:
            EmptyView()
        case .trial, .trialAvailable, .trialEnded:
            LabeledContent(copy.licenseKey) {
                HStack {
                    SecureField(copy.licenseKey, text: $licenseKey)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180, maxWidth: 280)
                        .onSubmit(activateLicense)
                    Button(copy.activateSync, action: activateLicense)
                        .disabled(billing.isWorking || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if billing.websiteOptions.isEmpty, let purchaseURL = LicenseManager.shared.purchaseURL {
                Link(destination: purchaseURL) {
                    Label(copy.buyLicense, systemImage: "cart")
                }
            }
        }
    }

    private func activateLicense() {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        run {
            await billing.activateDirectLicense(key)
            if billing.hasAccess { licenseKey = "" }
        }
    }
    #endif

    @ViewBuilder
    private func accessRow(_ summary: CloudSyncAccessSummary) -> some View {
        switch summary {
        case .trialAvailable:
            Button { run { await billing.startTrial() } } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(copy.startTrialTitle).font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                        Text(copy.trialNoCharge).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "gift").foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(billing.isWorking || !billing.accountConfigured)
        case let .trial(until):
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(copy.trialRemaining(CloudSyncAccessSummary.daysLeft(until))).foregroundStyle(.primary)
                    Text(copy.endsOn(until)).font(.caption)
                }
            } label: {
                Label(copy.trialTitle, systemImage: "gift")
            }
        case .trialEnded:
            Label(copy.trialEndedShort, systemImage: "clock")
                .foregroundStyle(.secondary)
        case let .subscribed(plan, until):
            Label(copy.accessActive, systemImage: "checkmark.icloud.fill")
                .foregroundStyle(.green)
            LabeledContent(copy.currentPlan, value: copy.planTitle(plan))
            LabeledContent(copy.currentPeriodEnds, value: until.formatted(date: .long, time: .omitted))
            Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                Label(copy.manageSubscriptions, systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            }
        case .lifetime:
            Label(copy.lifetimeUnlocked, systemImage: "checkmark.icloud.fill")
                .foregroundStyle(.green)
                .frame(minHeight: rowHeight)
        case let .website(until):
            Label(copy.websiteUnlocked, systemImage: "checkmark.icloud.fill")
                .foregroundStyle(.green)
            if let until {
                LabeledContent(copy.currentPeriodEnds, value: until.formatted(date: .long, time: .omitted))
            }
        }
    }

    private func messageRow(_ message: String) -> some View {
        let retryable = [copy.accountAccessFailed, copy.purchaseUnavailable, copy.purchaseFailed,
                         copy.purchaseBridgePending, copy.websitePaymentPending].contains(message)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: retryable ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(retryable ? .orange : .secondary)
                .accessibilityHidden(true)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("cloudSync.billingMessage")
            if retryable {
                Button(copy.retry) {
                    run {
                        if billing.products.isEmpty { await billing.loadProducts() } else { await billing.refresh() }
                    }
                }
                .buttonStyle(.borderless)
                .frame(minWidth: rowHeight, minHeight: rowHeight)
                .disabled(billing.isWorking)
            }
        }
    }

    private func planRow(_ plan: CloudSyncPlan, options: [CloudSyncPurchaseOption],
                         buy: @escaping @MainActor () async -> Void) -> some View {
        let product = options.first { $0.plan == plan }
        let savings = options.savingsPercent(for: plan)
        return Button { run(buy) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    let title = Text(copy.planTitle(plan)).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if let savings {
                        let badge = Text(copy.savings(savings))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) { title.fixedSize(); badge }
                            VStack(alignment: .leading, spacing: 4) { title; badge }
                        }
                    } else {
                        title
                    }
                    Text((billing.mode == .direct ? copy.websitePlanSubtitle(plan) : copy.planSubtitle(plan))).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(product?.displayPrice ?? "—")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(product == nil ? Color.secondary : Color.accentColor)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: rowHeight)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(product == nil || billing.isWorking)
        .accessibilityLabel([copy.planTitle(plan), product?.displayPrice, savings.map(copy.savings)]
            .compactMap { $0 }.joined(separator: "，"))
        .accessibilityHint((billing.mode == .direct ? copy.websitePlanSubtitle(plan) : copy.planSubtitle(plan)))
    }

    private var legalFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { legalLinks }
            VStack(alignment: .leading, spacing: 8) { legalLinks }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var legalLinks: some View {
        if let text = Bundle.main.object(forInfoDictionaryKey: "QCPrivacyPolicyURL") as? String,
           let url = URL(string: text), url.scheme == "https" {
            Link(copy.privacy, destination: url)
        }
        Link(copy.terms, destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
    }
    private func run(_ operation: @escaping @MainActor () async -> Void) {
        guard action == nil else { return }
        action = Task { await operation(); action = nil }
    }
}
