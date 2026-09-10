import Foundation

enum ApplicationLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese
    case english

    var id: Self { self }

    static var activeInterfaceLanguage: Self {
        let preferredLocalization = Bundle.main.preferredLocalizations.first
        if prefersChinese(preferredLocalization.map { [$0] } ?? []) {
            return .simplifiedChinese
        }
        return .english
    }

    var usesSimplifiedChinese: Bool {
        switch self {
        case .system:
            Self.prefersChinese(Locale.preferredLanguages)
        case .simplifiedChinese:
            true
        case .english:
            false
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            .autoupdatingCurrent
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        case .english:
            Locale(identifier: "en")
        }
    }

    func apply(to userDefaults: UserDefaults) {
        switch self {
        case .system:
            userDefaults.removeObject(forKey: "AppleLanguages")
        case .simplifiedChinese:
            userDefaults.set(["zh-Hans"], forKey: "AppleLanguages")
        case .english:
            userDefaults.set(["en"], forKey: "AppleLanguages")
        }
    }

    static func prefersChinese(_ languageIdentifiers: [String]) -> Bool {
        guard let identifier = languageIdentifiers.first else {
            return false
        }
        return Locale(identifier: identifier)
            .language
            .languageCode?
            .identifier == "zh"
    }
}
