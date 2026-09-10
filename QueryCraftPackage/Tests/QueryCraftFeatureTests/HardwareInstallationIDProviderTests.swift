import Foundation
import Testing

@testable import QueryCraftFeature

struct HardwareInstallationIDProviderTests {
    @Test
    func derivesStableNamespacedHashWithoutExposingHardwareUUID() throws {
        let rawUUID = "A1B2C3D4-E5F6-47A8-9012-3456789ABCDE"

        let identifier = try #require(
            HardwareInstallationIDProvider.makeInstallationID(
                platformUUID: rawUUID
            )
        )
        let normalizedIdentifier = try #require(
            HardwareInstallationIDProvider.makeInstallationID(
                platformUUID: "  \(rawUUID.lowercased())\n"
            )
        )

        #expect(identifier == normalizedIdentifier)
        #expect(identifier.hasPrefix("hw1-"))
        #expect(identifier.count == 68)
        #expect(!identifier.contains(rawUUID.lowercased()))
        #expect(
            identifier.dropFirst(4).allSatisfy {
                $0.isNumber || ("a"..."f").contains(String($0))
            }
        )
    }

    @Test
    func returnsNilWhenHardwareUUIDIsUnavailable() {
        let provider = HardwareInstallationIDProvider { nil }

        #expect(provider.installationID() == nil)
        #expect(
            HardwareInstallationIDProvider.makeInstallationID(
                platformUUID: "   "
            ) == nil
        )
    }

    @Test
    func differentHardwareProducesDifferentIdentifiers() throws {
        let first = try #require(
            HardwareInstallationIDProvider.makeInstallationID(
                platformUUID: "11111111-1111-1111-1111-111111111111"
            )
        )
        let second = try #require(
            HardwareInstallationIDProvider.makeInstallationID(
                platformUUID: "22222222-2222-2222-2222-222222222222"
            )
        )

        #expect(first != second)
    }
}

@Suite
struct HardwareLicenseEncryptionKeyMaterialProviderTests {
    @Test
    func derivesStableNamespacedMaterialWithoutExposingPlatformUUID() {
        let first = HardwareLicenseEncryptionKeyMaterialProvider {
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        }.encryptionKeyMaterial()
        let second = HardwareLicenseEncryptionKeyMaterialProvider {
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        }.encryptionKeyMaterial()

        #expect(first == second)
        #expect(first?.count == 64)
        #expect(!first.orEmpty.contains("aaaaaaaa-bbbb"))
    }

    @Test
    func returnsNilWithoutPlatformUUID() {
        let provider = HardwareLicenseEncryptionKeyMaterialProvider {
            nil
        }

        #expect(provider.encryptionKeyMaterial() == nil)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
