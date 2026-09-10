import SwiftUI

struct LicenseSettingsPane: View {
    @Bindable var preferences: ApplicationPreferences
    @State private var licenseManager = LicenseManager.shared
    @State private var licenseKey = ""
    @State private var presentedFailure: LicenseActionFailure?
    @State private var isConfirmingDeactivation = false

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        Form {
            Section(copy.licenseStatusSection) {
                LabeledContent(copy.licenseStatus) {
                    Label(
                        copy.title(for: licenseManager.state),
                        systemImage: copy.systemImage(for: licenseManager.state)
                    )
                }

                stateDetails

                HStack {
                    if showsActivationSection {
                        Spacer()
                    }

                    Button(
                        copy.checkLicenseStatus,
                        systemImage: "arrow.clockwise"
                    ) {
                        Task { await refresh() }
                    }
                    .disabled(licenseManager.isWorking)

                    if !showsActivationSection {
                        Spacer()

                        Button(
                            copy.deactivateLicense,
                            systemImage: "xmark.circle",
                            role: .destructive
                        ) {
                            isConfirmingDeactivation = true
                        }
                        .disabled(licenseManager.isWorking)
                    }
                }
            }

            if showsActivationSection {
                Section(copy.activateLicenseSection) {
                    LabeledContent(copy.licenseKey) {
                        TextField(
                            "",
                            text: $licenseKey,
                            prompt: Text(copy.licenseKeyPlaceholder)
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                        .onSubmit(activateIfPossible)
                    }

                    HStack {
                        if let purchaseURL = licenseManager.purchaseURL {
                            Link(
                                copy.purchaseLicense,
                                destination: purchaseURL
                            )
                        }

                        Spacer()

                        Button(
                            copy.activateLicense,
                            systemImage: "key.fill"
                        ) {
                            Task { await activate() }
                        }
                        .disabled(!canActivate)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .task {
            await licenseManager.prepare()
        }
        .alert(item: $presentedFailure) { failure in
            Alert(
                title: Text(copy.licenseActionFailed),
                message: Text(copy.message(for: failure)),
                dismissButton: .default(Text(copy.ok))
            )
        }
        .confirmationDialog(
            copy.deactivateLicenseConfirmation,
            isPresented: $isConfirmingDeactivation
        ) {
            Button(copy.deactivateLicense, role: .destructive) {
                Task { await deactivate() }
            }
            .keyboardShortcut(.defaultAction)
            Button(copy.cancel, role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var stateDetails: some View {
        switch licenseManager.state {
        case let .trial(expiresAt):
            LabeledContent(copy.expires) {
                Text(expiresAt, format: .dateTime.year().month().day())
            }
        case let .paid(plan, expiresAt, maximumActivations):
            LabeledContent(copy.plan) {
                Text(copy.title(for: plan))
            }
            if let expiresAt {
                LabeledContent(copy.expires) {
                    Text(expiresAt, format: .dateTime.year().month().day())
                }
            }
            LabeledContent(copy.deviceLimit) {
                Text(copy.deviceCount(maximumActivations))
            }
        case let .offlineGrace(plan, expiresAt, validUntil):
            LabeledContent(copy.plan) {
                Text(copy.title(for: plan))
            }
            if let expiresAt {
                LabeledContent(copy.expires) {
                    Text(expiresAt, format: .dateTime.year().month().day())
                }
            }
            LabeledContent(copy.offlineAccessUntil) {
                Text(validUntil, format: .dateTime.year().month().day())
            }
        case .loading, .unrestrictedDevelopment, .restricted:
            EmptyView()
        }
    }

    private var showsActivationSection: Bool {
        if case .paid = licenseManager.state {
            return false
        }
        if case let .offlineGrace(plan, _, _) = licenseManager.state,
            plan != .trial
        {
            return false
        }
        return true
    }

    private var canActivate: Bool {
        !licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !licenseManager.isWorking
    }

    private func activate() async {
        do {
            try await licenseManager.activate(licenseKey: licenseKey)
            licenseKey = ""
        } catch let failure as LicenseActionFailure {
            presentedFailure = failure
        } catch {
            presentedFailure = .serviceUnavailable
        }
    }

    private func activateIfPossible() {
        guard canActivate else { return }
        Task { await activate() }
    }

    private func refresh() async {
        do {
            try await licenseManager.refresh()
        } catch let failure as LicenseActionFailure {
            presentedFailure = failure
        } catch {
            presentedFailure = .serviceUnavailable
        }
    }

    private func deactivate() async {
        do {
            try await licenseManager.deactivate()
        } catch let failure as LicenseActionFailure {
            presentedFailure = failure
        } catch {
            presentedFailure = .serviceUnavailable
        }
    }
}
