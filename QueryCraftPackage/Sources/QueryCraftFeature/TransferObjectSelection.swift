import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

enum TransferObjectSelection {
    struct Matches {
        let objects: [TransferObject]
        let missing: [String]
        var feedback: String {
            AppCopy.current.text("匹配 \(objects.count) 个对象", "Matched \(objects.count) objects")
                + (missing.isEmpty ? "" : AppCopy.current.text("；未匹配：", "; unmatched: ") + missing.joined(separator: ", "))
        }
    }
    static func filtered(_ objects: [TransferObject], search: String) -> [TransferObject] {
        objects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    static func match(_ source: String, objects: [TransferObject], namespace: String,
                      enabled: (TransferObject) -> Bool) -> Matches {
        let names = source.components(separatedBy: CharacterSet(charactersIn: ",;\n\r\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var missing: [String] = [], result: [TransferObject] = []
        for name in names {
            let matches = objects.filter { object in
                guard enabled(object) else { return false }
                if object.name == name || "\(namespace).\(object.name)" == name { return true }
                let parts = (try? TransferSQL.tokens(name))?.filter(\.identifier).map(\.value) ?? []
                return parts == [object.name] || parts == [namespace, object.name]
            }
            if matches.isEmpty { missing.append(name) }
            result += matches
        }
        return .init(objects: result, missing: missing)
    }
}
