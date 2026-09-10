import Foundation
import Testing

@testable import QueryCraftFeature

struct LicensingConfigurationTests {
    @Test
    func environmentOverridesLocalDevelopmentEndpointsAndPublicKey() throws {
        let publicKey = Data(repeating: 7, count: 32)
        let configuration = LicensingConfiguration.applicationDefault(
            environment: [
                "QUERYCRAFT_ENABLE_LICENSING": "1",
                "QUERYCRAFT_LICENSE_API_BASE_URL": "http://127.0.0.1:8787/api/v1/",
                "QUERYCRAFT_LICENSE_PURCHASE_URL": "http://127.0.0.1:8787/",
                "QUERYCRAFT_LICENSE_PUBLIC_KEY": publicKey.base64EncodedString(),
            ]
        )

        #expect(configuration.apiBaseURL?.absoluteString == "http://127.0.0.1:8787/api/v1/")
        #expect(configuration.purchaseURL?.absoluteString == "http://127.0.0.1:8787/")
        #expect(configuration.publicKey == publicKey)
    }
}
