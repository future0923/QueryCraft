import Foundation

public struct RedisBinaryValue: Equatable, Hashable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(utf8 value: String) {
        data = Data(value.utf8)
    }

    public var losslessUTF8String: String? {
        String(data: data, encoding: .utf8)
    }
}
