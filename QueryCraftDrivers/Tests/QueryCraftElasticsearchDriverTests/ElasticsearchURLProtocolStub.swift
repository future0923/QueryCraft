import Foundation
import Synchronization

final class ElasticsearchURLProtocolStub: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws
        -> (HTTPURLResponse, Data)

    private struct Registration: Sendable {
        let handler: Handler
        let finishesLoading: Bool
        let onStop: @Sendable () -> Void
    }

    private static let handlers = Mutex<[String: Registration]>([:])

    static func install(
        for host: String,
        finishesLoading: Bool = true,
        onStop: @escaping @Sendable () -> Void = {},
        _ newHandler: @escaping Handler
    ) {
        handlers.withLock {
            $0[host] = Registration(handler: newHandler,
                finishesLoading: finishesLoading, onStop: onStop)
        }
    }

    static func reset(host: String) {
        handlers.withLock { $0[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host,
              let registration = Self.handlers.withLock({ $0[host] })
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        do {
            let (response, data) = try registration.handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            if registration.finishesLoading {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.handlers.withLock { $0[host] }?.onStop()
    }

    static func response(
        for request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [
            "Content-Type": "application/json",
        ],
        json: String = "{}"
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, Data(json.utf8))
    }
}
