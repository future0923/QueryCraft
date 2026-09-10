import SwiftUI

struct LicenseActivationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var licenseManager = LicenseManager.shared
    @State private var preferences = ApplicationPreferences.shared
    @State private var licenseKey = ""
    @State private var presentedFailure: LicenseActionFailure?
    @FocusState private var isLicenseKeyFocused: Bool

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(copy.activateLicense)
                    .font(.title2.weight(.semibold))

                Text(copy.licenseActivationDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            VStack(spacing: 10) {
                TextField(
                    "",
                    text: $licenseKey,
                    prompt: Text(copy.licenseKeyPlaceholder)
                )
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .multilineTextAlignment(.center)
                .focused($isLicenseKeyFocused)
                .disabled(licenseManager.isWorking)
                .onSubmit(activateIfPossible)

                if let presentedFailure {
                    Label(
                        copy.message(for: presentedFailure),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            VStack(spacing: 10) {
                Button {
                    Task { await activate() }
                } label: {
                    if licenseManager.isWorking {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text(copy.activatingLicense)
                        }
                    } else {
                        Text(copy.activateLicense)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canActivate)

                HStack(spacing: 18) {
                    if let purchaseURL = licenseManager.purchaseURL {
                        Link(copy.purchaseLicense, destination: purchaseURL)
                    }

                    Button(copy.cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(licenseManager.isWorking)
                }
                .font(.subheadline)
            }
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(width: 420)
        .defaultFocus($isLicenseKeyFocused, true)
        .interactiveDismissDisabled(licenseManager.isWorking)
    }

    private var canActivate: Bool {
        !licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !licenseManager.isWorking
    }

    private func activateIfPossible() {
        guard canActivate else { return }
        Task { await activate() }
    }

    private func activate() async {
        guard canActivate else { return }
        presentedFailure = nil

        do {
            try await licenseManager.activate(licenseKey: licenseKey)
            dismiss()
        } catch let failure as LicenseActionFailure {
            presentedFailure = failure
        } catch {
            presentedFailure = .serviceUnavailable
        }
    }
}
