import SwiftUI

struct WelcomeLicenseSummaryView: View {
    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(versionTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(copy.allCurrentFeaturesFree, systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var versionTitle: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"
        return AppCopy(language: .activeInterfaceLanguage).text(
            "版本 \(version)",
            "Version \(version)"
        )
    }

}
