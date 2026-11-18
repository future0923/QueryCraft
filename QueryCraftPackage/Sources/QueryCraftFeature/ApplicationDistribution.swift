import Foundation

/// The signed host chooses how executable components are delivered. Billing
/// mode alone cannot enable downloading code in the App Store distribution.
enum ApplicationDistribution: String, Sendable {
    case direct, appStore

    static var current: Self {
        Bundle.main.object(forInfoDictionaryKey: "QCDistributionChannel") as? String == "appStore" ? .appStore : .direct
    }

    var supportsDownloadedCode: Bool { self == .direct }

    static var bundledDriversDirectory: URL {
        Bundle.main.bundleURL.appending(path: "Contents/PlugIns/Drivers", directoryHint: .isDirectory)
    }

    static func requireDownloadedCode() throws {
        guard current.supportsDownloadedCode else { throw ComponentDistributionError.managedByAppStore }
    }
}

enum ComponentDistributionError: LocalizedError {
    case managedByAppStore
    var errorDescription: String? {
        AppCopy.current.text("组件随 App Store 版本提供，请通过 App Store 更新应用。",
                             "Components are included with the app. Update QueryCraft through the App Store.")
    }
}
