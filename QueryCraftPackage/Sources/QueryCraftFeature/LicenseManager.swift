import Foundation
import Observation

enum LicenseActionFailure: Error, Equatable, Identifiable {
    case invalidLicenseKey
    case expired
    case suspended
    case activationLimitReached
    case activationMissing
    case serviceUnavailable
    case secureStorageUnavailable
    case invalidServerResponse

    var id: Self { self }
}

@MainActor
@Observable
public final class LicenseManager {
    public static let shared = LicenseManager.makeApplicationDefault()

    private static let offlineRetryInterval: TimeInterval = 60 * 60

    private(set) var state: LicenseState = .loading
    private(set) var isWorking = false

    var purchaseURL: URL? { configuration.purchaseURL }

    @ObservationIgnored private let configuration: LicensingConfiguration
    @ObservationIgnored private let service: (any LicenseServiceClient)?
    @ObservationIgnored private let credentialStore: any LicenseCredentialStore
    @ObservationIgnored private let installationIDProvider: any InstallationIDProviding
    @ObservationIgnored private let verifier: LicenseTokenVerifier?
    @ObservationIgnored private let accessGate: LicenseAccessGate
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?

    init(
        configuration: LicensingConfiguration,
        service: (any LicenseServiceClient)?,
        credentialStore: any LicenseCredentialStore,
        installationIDProvider: any InstallationIDProviding =
            HardwareInstallationIDProvider(),
        verifier: LicenseTokenVerifier?,
        accessGate: LicenseAccessGate = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.configuration = configuration
        self.service = service
        self.credentialStore = credentialStore
        self.installationIDProvider = installationIDProvider
        self.verifier = verifier
        self.accessGate = accessGate
        self.now = now
        self.deviceName = deviceName
    }

    isolated deinit {
        preparationTask?.cancel()
        boundaryTask?.cancel()
    }

    public func start() {
        guard preparationTask == nil else { return }
        preparationTask = Task { @MainActor [weak self] in
            await self?.performPreparation()
        }
    }

    public func prepare() async {
        start()
        await preparationTask?.value
    }

    func activate(licenseKey: String) async throws {
        try await withWorkingState {
            guard let service, let verifier else {
                throw LicenseActionFailure.invalidServerResponse
            }
            let installationID = try await self.installationID()
            let entitlement: SignedLicenseEntitlement
            do {
                entitlement = try await service.activate(
                    licenseKey: licenseKey,
                    installationID: installationID,
                    deviceName: deviceName
                )
            } catch {
                throw self.actionFailure(for: error)
            }
            do {
                let payload = try verifier.verify(
                    entitlement,
                    installationID: installationID
                )
                guard let deviceCredential = entitlement.deviceCredential else {
                    throw LicenseActionFailure.invalidServerResponse
                }
                try await credentialStore.saveDeviceCredential(deviceCredential)
                try await apply(
                    entitlement: entitlement,
                    payload: payload,
                    usesOfflineGrace: false
                )
            } catch let failure as LicenseActionFailure {
                throw failure
            } catch is LicenseCredentialStoreError {
                throw LicenseActionFailure.secureStorageUnavailable
            } catch {
                throw LicenseActionFailure.invalidServerResponse
            }
        }
    }

    func refresh() async throws {
        try await withWorkingState {
            try await refreshWithCachedFallback()
        }
    }

    func deactivate() async throws {
        try await withWorkingState {
            guard let service else {
                throw LicenseActionFailure.invalidServerResponse
            }
            let installationID = try await self.installationID()
            guard let deviceCredential = try await credentialStore.deviceCredential() else {
                throw LicenseActionFailure.activationMissing
            }
            do {
                try await service.deactivate(
                    deviceCredential: deviceCredential,
                    installationID: installationID
                )
                try await credentialStore.clearPaidLicense()
                try await startOrResumeTrial(installationID: installationID)
            } catch let failure as LicenseActionFailure {
                throw failure
            } catch is LicenseCredentialStoreError {
                throw LicenseActionFailure.secureStorageUnavailable
            } catch {
                throw self.actionFailure(for: error)
            }
        }
    }

    private static func makeApplicationDefault() -> LicenseManager {
        let configuration = LicensingConfiguration.applicationDefault()
        let installationIDProvider = HardwareInstallationIDProvider()
        let encryptionKeyMaterial =
            HardwareLicenseEncryptionKeyMaterialProvider().encryptionKeyMaterial()
        let verifier = configuration.publicKey.flatMap {
            try? LicenseTokenVerifier(publicKeyData: $0)
        }
        let service = configuration.apiBaseURL.map {
            HTTPLicenseServiceClient(baseURL: $0)
        }
        guard let encryptionKeyMaterial else {
            return LicenseManager(
                configuration: configuration,
                service: service,
                credentialStore: UnavailableLicenseCredentialStore(),
                installationIDProvider: installationIDProvider,
                verifier: verifier
            )
        }
        return LicenseManager(
            configuration: configuration,
            service: service,
            credentialStore: FileLicenseCredentialStore(
                encryptionKeyMaterial: encryptionKeyMaterial
            ),
            installationIDProvider: installationIDProvider,
            verifier: verifier
        )
    }

    private func performPreparation() async {
        guard configuration.isEnabled else {
            await updateState(.unrestrictedDevelopment)
            return
        }
        guard service != nil, verifier != nil else {
            await updateState(.restricted(.configurationInvalid))
            return
        }
        do {
            try await prepareEnabledLicensing()
        } catch is LicenseCredentialStoreError {
            await updateState(.restricted(.configurationInvalid))
        } catch {
            await updateState(.restricted(.serviceUnavailable))
        }
    }

    private func prepareEnabledLicensing() async throws {
        let installationID = try await self.installationID()
        let cachedEntitlement = try await credentialStore.signedEntitlement()
        let cachedPayload = cachedEntitlement.flatMap {
            try? verifier?.verify($0, installationID: installationID)
        }
        let effectiveNow = try await effectiveNow()

        if let cachedPayload {
            await applyState(
                payload: cachedPayload,
                effectiveNow: effectiveNow,
                usesOfflineGrace: false
            )
        }

        do {
            try await refreshFromServer()
        } catch {
            if let cachedPayload, canUseOfflineGrace(for: error) {
                await applyState(
                    payload: cachedPayload,
                    effectiveNow: effectiveNow,
                    usesOfflineGrace: true
                )
            } else {
                await updateState(restrictedState(for: error))
            }
        }
    }

    private func refreshFromServer() async throws {
        guard let service, let verifier else {
            throw LicenseActionFailure.invalidServerResponse
        }
        let installationID = try await self.installationID()
        let entitlement: SignedLicenseEntitlement
        if let deviceCredential = try await credentialStore.deviceCredential() {
            entitlement = try await service.validate(
                deviceCredential: deviceCredential,
                installationID: installationID
            )
        } else {
            entitlement = try await service.startTrial(
                installationID: installationID,
                deviceName: deviceName
            )
        }

        let payload = try verifier.verify(
            entitlement,
            installationID: installationID
        )
        try await apply(
            entitlement: entitlement,
            payload: payload,
            usesOfflineGrace: false
        )
    }

    private func refreshWithCachedFallback() async throws {
        do {
            try await refreshFromServer()
        } catch {
            guard canUseOfflineGrace(for: error) else {
                await updateState(restrictedState(for: error))
                throw actionFailure(for: error)
            }
            do {
                let installationID = try await self.installationID()
                guard
                    let entitlement = try await credentialStore.signedEntitlement(),
                    let payload = try verifier?.verify(
                        entitlement,
                        installationID: installationID
                    )
                else {
                    await updateState(.restricted(.serviceUnavailable))
                    throw LicenseActionFailure.serviceUnavailable
                }
                let effectiveNow = try await effectiveNow()
                await applyState(
                    payload: payload,
                    effectiveNow: effectiveNow,
                    usesOfflineGrace: true
                )
            } catch let failure as LicenseActionFailure {
                throw failure
            } catch is LicenseCredentialStoreError {
                await updateState(.restricted(.configurationInvalid))
                throw LicenseActionFailure.secureStorageUnavailable
            } catch {
                await updateState(.restricted(.configurationInvalid))
                throw LicenseActionFailure.invalidServerResponse
            }
        }
    }

    private func startOrResumeTrial(installationID: String) async throws {
        guard let service, let verifier else {
            throw LicenseActionFailure.invalidServerResponse
        }
        do {
            let entitlement = try await service.startTrial(
                installationID: installationID,
                deviceName: deviceName
            )
            let payload = try verifier.verify(
                entitlement,
                installationID: installationID
            )
            try await apply(
                entitlement: entitlement,
                payload: payload,
                usesOfflineGrace: false
            )
        } catch {
            await updateState(restrictedState(for: error))
            throw actionFailure(for: error)
        }
    }

    private func apply(
        entitlement: SignedLicenseEntitlement,
        payload: LicenseEntitlementPayload,
        usesOfflineGrace: Bool
    ) async throws {
        try await credentialStore.saveSignedEntitlement(
            SignedLicenseEntitlement(
                payload: entitlement.payload,
                signature: entitlement.signature
            )
        )
        let serverTime = Date(
            timeIntervalSince1970: TimeInterval(payload.issuedAt)
        )
        let effectiveNow = max(now(), serverTime)
        try await credentialStore.saveLastObservedTime(effectiveNow)
        await applyState(
            payload: payload,
            effectiveNow: effectiveNow,
            usesOfflineGrace: usesOfflineGrace
        )
    }

    private func applyState(
        payload: LicenseEntitlementPayload,
        effectiveNow: Date,
        usesOfflineGrace: Bool
    ) async {
        let resolvedState = LicenseStateResolver.resolve(
            payload: payload,
            now: effectiveNow,
            usesOfflineGrace: usesOfflineGrace
        )
        state = resolvedState
        if resolvedState.permitsDatabaseAccess {
            scheduleNextBoundary(
                payload: payload,
                now: effectiveNow,
                usesOfflineGrace: usesOfflineGrace
            )
        } else {
            boundaryTask?.cancel()
            boundaryTask = nil
        }
        await accessGate.update(for: resolvedState)
    }

    private func updateState(_ newState: LicenseState) async {
        state = newState
        await accessGate.update(for: newState)
        if !newState.permitsDatabaseAccess {
            boundaryTask?.cancel()
            boundaryTask = nil
        }
    }

    private func scheduleNextBoundary(
        payload: LicenseEntitlementPayload,
        now: Date,
        usesOfflineGrace: Bool
    ) {
        boundaryTask?.cancel()
        guard let boundary = Self.nextRefreshDate(
            payload: payload,
            now: now,
            usesOfflineGrace: usesOfflineGrace
        ) else { return }
        let delay = boundary.timeIntervalSince(now)
        boundaryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try await self?.refresh()
            } catch is CancellationError {
                return
            } catch {
                // refresh() already publishes the corresponding restricted state.
            }
        }
    }

    static func nextRefreshDate(
        payload: LicenseEntitlementPayload,
        now: Date,
        usesOfflineGrace: Bool
    ) -> Date? {
        var candidates = [
            payload.expiresAt,
            payload.validationDueAt,
            payload.offlineValidUntil,
        ].compactMap { $0 }.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        if usesOfflineGrace {
            candidates.append(
                now.addingTimeInterval(Self.offlineRetryInterval)
            )
        }
        return candidates.filter { $0 > now }.min()
    }

    private func installationID() async throws -> String {
        if let hardwareID = installationIDProvider.installationID() {
            if try await credentialStore.installationID() != hardwareID {
                try await credentialStore.saveInstallationID(hardwareID)
            }
            return hardwareID
        }
        if let existing = try await credentialStore.installationID() {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        try await credentialStore.saveInstallationID(value)
        return value
    }

    private func effectiveNow() async throws -> Date {
        let current = now()
        let previous = try await credentialStore.lastObservedTime()
        let effective = max(current, previous ?? current)
        try await credentialStore.saveLastObservedTime(effective)
        return effective
    }

    private func restrictedState(for error: Error) -> LicenseState {
        if error is LicenseTokenVerificationError ||
            error is LicenseCredentialStoreError {
            return .restricted(.configurationInvalid)
        }
        guard let serviceError = error as? LicenseServiceError else {
            return .restricted(.serviceUnavailable)
        }
        switch serviceError {
        case .trialExpired:
            return .restricted(.trialExpired)
        case .licenseExpired:
            return .restricted(.licenseExpired)
        case .licenseSuspended:
            return .restricted(.licenseSuspended)
        case .activationMissing:
            return .restricted(.activationMissing)
        case .licenseNotFound:
            return .restricted(.activationMissing)
        case .invalidRequest, .invalidResponse:
            return .restricted(.configurationInvalid)
        case .activationLimitReached, .serverUnavailable:
            return .restricted(.serviceUnavailable)
        }
    }

    private func actionFailure(for error: Error) -> LicenseActionFailure {
        if let failure = error as? LicenseActionFailure {
            return failure
        }
        if error is LicenseCredentialStoreError {
            return .secureStorageUnavailable
        }
        if error is LicenseTokenVerificationError {
            return .invalidServerResponse
        }
        guard let serviceError = error as? LicenseServiceError else {
            return .serviceUnavailable
        }
        switch serviceError {
        case .licenseNotFound, .invalidRequest:
            return .invalidLicenseKey
        case .licenseExpired, .trialExpired:
            return .expired
        case .licenseSuspended:
            return .suspended
        case .activationLimitReached:
            return .activationLimitReached
        case .activationMissing:
            return .activationMissing
        case .invalidResponse:
            return .invalidServerResponse
        case .serverUnavailable:
            return .serviceUnavailable
        }
    }

    private func canUseOfflineGrace(for error: Error) -> Bool {
        if let failure = error as? LicenseActionFailure {
            return failure == .serviceUnavailable
        }
        return error as? LicenseServiceError == .serverUnavailable
    }

    private func withWorkingState(
        _ operation: () async throws -> Void
    ) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        try await operation()
    }
}
