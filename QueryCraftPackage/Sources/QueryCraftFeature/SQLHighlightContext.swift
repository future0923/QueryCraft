import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif
import CryptoKit

/// Only changes the display tree. Execution/formatting always consume the original source tree.
struct SQLHighlightContext: Equatable, Hashable, Sendable {
    enum Dialect: String, Sendable { case generic, mysql, postgresql, doris }
    var dialect: Dialect = .generic
    var ansiQuotes = false
    static let generic = Self()

    init(databaseType: DatabaseType? = nil, ansiQuotes: Bool = false) {
        switch databaseType {
        case .mysql: dialect = .mysql
        case .postgresql: dialect = .postgresql
        case .doris: dialect = .doris
        default: dialect = .generic
        }
        self.ansiQuotes = ansiQuotes
    }

    func displaySource(_ source: String) -> String? {
        guard dialect == .postgresql || ((dialect == .mysql || dialect == .doris) && ansiQuotes),
              source.contains("\"") else { return nil }
        let result = NSMutableString(string: source)
        var changed = false
        for token in SQLLexicalHighlightRecovery.tokens(in: source).reversed()
        where token.kind == nil && token.text.hasPrefix("\"") && token.text.hasSuffix("\"") && token.text.count >= 2 {
            // Preserve every UTF-16 offset, including escaped quotes and literal backticks.
            let replacement = token.text.replacingOccurrences(of: "`", with: "_").replacingOccurrences(of: "\"", with: "`")
            result.replaceCharacters(in: token.range, with: replacement)
            changed = true
        }
        return changed ? result as String : nil
    }

    #if !os(iOS)
    static func connectionKey(_ configuration: DatabaseConnectionConfiguration) -> String {
        let parts = [configuration.databaseType.rawValue, configuration.host.lowercased(), String(configuration.port), configuration.username]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    #endif
}
