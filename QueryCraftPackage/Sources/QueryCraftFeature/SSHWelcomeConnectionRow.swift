import AppKit
import SwiftUI

struct SSHWelcomeConnectionRow: View {
    let profile: SSHConnection
    var isSelected = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 20)).frame(width: 22, height: 22)
                .foregroundStyle(isSelected ? Color.primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).font(.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "\(profile.username) @ \(profile.host):\(profile.port)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading).help("SSH · \(profile.username)@\(profile.host):\(profile.port)")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 3).padding(.trailing, 6)
            .accessibilityElement(children: .combine).accessibilityLabel("SSH · \(profile.name)")
    }
}

@MainActor final class SSHConnectionHostingView: NSHostingView<SSHWelcomeConnectionRow> {
    private let profile: SSHConnection
    private var selected = false
    init(profile: SSHConnection) {
        self.profile = profile
        super.init(rootView: SSHWelcomeConnectionRow(profile: profile))
        setAccessibilityIdentifier("sshConnectionRow.\(profile.id)")
    }
    @available(*, unavailable) required init(rootView: SSHWelcomeConnectionRow) { fatalError("Use init(profile:)") }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func setSelectedAppearance(_ value: Bool) {
        guard value != selected else { return }; selected = value
        rootView = SSHWelcomeConnectionRow(profile: profile, isSelected: value)
    }
}

enum SSHWelcomeSearch {
    static func filter(_ profiles: [SSHConnection], query: String) -> [SSHConnection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = query.isEmpty || "SSH".localizedStandardContains(query)
            || AppCopy.current.text("SSH 服务器", "SSH Servers").localizedStandardContains(query)
        return profiles.filter { all || $0.name.localizedStandardContains(query)
            || "\($0.username)@\($0.host):\($0.port)".localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
