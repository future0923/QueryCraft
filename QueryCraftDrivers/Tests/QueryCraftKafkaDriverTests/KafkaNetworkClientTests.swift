import Foundation
import Network
import QueryCraftFeature
import Testing
@testable import QueryCraftKafkaDriver

@Suite("Kafka network client")
struct KafkaNetworkClientTests {
    @Test("Invalidates a failed request and can reconnect")
    func requestFailureInvalidatesConnection() async throws {
        let server = try KafkaTestListener()
        defer { server.stop() }
        try await server.start()

        let configuration = try KafkaConnectionConfiguration(
            DatabaseConnectionConfiguration(
                databaseType: .kafka,
                databaseProduct: .kafka,
                host: "127.0.0.1",
                port: server.port,
                authentication: .none,
                database: nil,
                tlsMode: .disabled
            )
        )
        let client = KafkaNetworkClient(configuration: configuration)

        try await client.connect()
        await server.waitForAcceptedConnection()
        server.closeAcceptedConnections()

        do {
            _ = try await client.metadata()
            Issue.record("metadata unexpectedly succeeded after the peer closed the socket")
        } catch {
            // The request is expected to fail because the test peer does not
            // send a Kafka response after closing the accepted socket.
        }
        #expect(!client.isConnected())

        try await client.connect()
        #expect(client.isConnected())
    }
}

private final class KafkaTestListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.github.future0923.QueryCraft.kafka.tests")
    private let lock = NSLock()
    private var acceptedConnections: [NWConnection] = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var acceptedContinuation: CheckedContinuation<Void, Never>?
    private var startError: Error?

    init() throws {
        guard let port = NWEndpoint.Port(rawValue: 0) else {
            throw KafkaError.invalidConfiguration("invalid test listener port")
        }
        listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.lock()
            self.acceptedConnections.append(connection)
            let continuation = self.acceptedContinuation
            self.acceptedContinuation = nil
            self.lock.unlock()
            connection.start(queue: self.queue)
            continuation?.resume()
        }
    }

    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(listener.port?.rawValue ?? 0)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            startContinuation = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    let continuation = self.startContinuation
                    self.startContinuation = nil
                    self.lock.unlock()
                    continuation?.resume()
                case .failed(let error):
                    self.lock.lock()
                    self.startError = error
                    let continuation = self.startContinuation
                    self.startContinuation = nil
                    self.lock.unlock()
                    continuation?.resume(throwing: KafkaError.network(error.localizedDescription))
                case .cancelled:
                    self.lock.lock()
                    let continuation = self.startContinuation
                    self.startContinuation = nil
                    self.lock.unlock()
                    continuation?.resume(throwing: KafkaError.network("test listener cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        if let startError {
            throw startError
        }
    }

    func waitForAcceptedConnection() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if acceptedConnections.isEmpty {
                acceptedContinuation = continuation
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func closeAcceptedConnections() {
        lock.lock()
        let connections = acceptedConnections
        acceptedConnections.removeAll()
        lock.unlock()
        connections.forEach { $0.cancel() }
    }

    func stop() {
        lock.lock()
        let connections = acceptedConnections
        acceptedConnections.removeAll()
        let continuation = startContinuation
        startContinuation = nil
        let acceptedContinuation = self.acceptedContinuation
        self.acceptedContinuation = nil
        lock.unlock()
        connections.forEach { $0.cancel() }
        continuation?.resume(throwing: KafkaError.network("test listener stopped"))
        acceptedContinuation?.resume()
        listener.cancel()
    }
}
