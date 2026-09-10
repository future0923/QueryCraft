import Foundation

struct LicensingConfiguration: Sendable {
    let isEnabled: Bool
    let apiBaseURL: URL?
    let publicKey: Data?
    let purchaseURL: URL?

    init(
        isEnabled: Bool,
        apiBaseURL: URL?,
        publicKey: Data?,
        purchaseURL: URL?
    ) {
        self.isEnabled = isEnabled
        self.apiBaseURL = apiBaseURL
        self.publicKey = publicKey
        self.purchaseURL = purchaseURL
    }

    static func applicationDefault(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LicensingConfiguration {
        let values = bundle.infoDictionary ?? [:]
        let configuredEnabled = values["QCLicenseEnforcementEnabled"] as? Bool
            ?? false
        let isEnabled: Bool
        #if DEBUG
        isEnabled = configuredEnabled
            && environment["QUERYCRAFT_ENABLE_LICENSING"] == "1"
        #else
        isEnabled = configuredEnabled
        #endif

        let configuredBaseURL = environment["QUERYCRAFT_LICENSE_API_BASE_URL"]
            ?? values["QCLicenseAPIBaseURL"] as? String
        let publicKeyText = environment["QUERYCRAFT_LICENSE_PUBLIC_KEY"]
            ?? values["QCLicensePublicKey"] as? String
        let purchaseURLText = environment["QUERYCRAFT_LICENSE_PURCHASE_URL"]
            ?? values["QCLicensePurchaseURL"] as? String

        return LicensingConfiguration(
            isEnabled: isEnabled,
            apiBaseURL: configuredBaseURL.flatMap(URL.init(string:)),
            publicKey: publicKeyText.flatMap { Data(base64Encoded: $0) },
            purchaseURL: purchaseURLText.flatMap(URL.init(string:))
        )
    }
}
