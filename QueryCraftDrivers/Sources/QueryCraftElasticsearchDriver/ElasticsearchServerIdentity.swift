import Foundation

enum ElasticsearchServerIdentity {
    static func version(body: Data, headers: [String: String]) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let version = (root["version"] as? [String: Any])?["number"] as? String,
              headers["x-elastic-product"] == "Elasticsearch" || root["tagline"] as? String == "You Know, for Search" else {
            throw ElasticsearchError.unsupportedProduct
        }
        guard isSupported(version: version) else { throw ElasticsearchError.unsupportedVersion(version) }
        return version
    }
    static func isSupported(version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        if major > 7 { return true }
        return major == 7 && parts.dropFirst().first.map { $0 >= 10 } == true
    }
}
