import Foundation
import QueryCraftFeature
import Security

final class ElasticsearchURLSessionDelegate: NSObject, URLSessionTaskDelegate,
    Sendable
{
    private let tlsMode: ConnectionTLSMode

    init(tlsMode: ConnectionTLSMode) {
        self.tlsMode = tlsMode
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // REST writes must not be replayed at another URL or leak credentials.
        completionHandler(nil)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch tlsMode {
        case .disabled, .verifyIdentity:
            completionHandler(.performDefaultHandling, nil)
        case .required:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .verifyCA:
            let policy = SecPolicyCreateSSL(true, nil)
            guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil)
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
