import Foundation
import Network
import QueryCraftFeature
import Security

struct KafkaFetchRequestPartition: Equatable, Sendable {
    let partition: Int32
    let offset: Int64
    let maximumBytes: Int32
}

struct KafkaFetchRequestTopic: Equatable, Sendable {
    let name: String
    let partitions: [KafkaFetchRequestPartition]
}

/// A small, serial Kafka protocol client used by the read-only workspace
/// driver. Requests are sent one at a time, which keeps correlation handling
/// deterministic and is sufficient for metadata and paged browsing.
final class KafkaNetworkClient: @unchecked Sendable {
    private static let maximumFrameLength = 64 * 1024 * 1024

    private let configuration: KafkaConnectionConfiguration
    private let queue = DispatchQueue(
        label: "io.github.future0923.QueryCraft.kafka",
        qos: .userInitiated
    )
    private var connection: NWConnection?
    private var connectedAddress: KafkaBrokerAddress?
    private var nextCorrelationID: Int32 = 1

    init(configuration: KafkaConnectionConfiguration) {
        self.configuration = configuration
    }

    func connect() async throws {
        // A failed or cancelled NWConnection can remain retained until its
        // cancellation callback runs. Treat only a ready socket as connected;
        // otherwise discard it and walk the bootstrap list again.
        if let connection {
            guard connection.state == .ready else {
                invalidateConnection()
                return try await connect()
            }
            return
        }
        var lastError: Error?
        for address in configuration.bootstrapServers {
            do {
                try await connect(to: address)
                return
            } catch {
                lastError = error
                close()
            }
        }
        throw lastError ?? KafkaError.network("no bootstrap server is available")
    }

    func close() {
        invalidateConnection()
    }

    func isConnected() -> Bool {
        connection?.state == .ready
    }

    func metadata() async throws -> KafkaMetadataResponse {
        let response = try await request(
            apiKey: 3,
            version: KafkaMetadataRequestEncoder.version,
            body: KafkaMetadataRequestEncoder.encodeAllTopics()
        )
        return try KafkaMetadataDecoder.decodeResponse(
            response,
            // Metadata v1 starts with the broker array.  Throttle time was
            // added in a later response version.
            includesThrottleTime: false,
            includesBrokerRack: true,
            includesControllerMetadata: true,
            includesInternalTopicFlag: true
        )
    }

    func listOffsets(
        topics: [KafkaListOffsetsRequestTopic],
        broker: KafkaBrokerAddress
    ) async throws -> KafkaListOffsetsResponse {
        if connectedAddress != broker || !isConnected() {
            close()
            try await connect(to: broker)
        }
        let response = try await request(
            apiKey: 2,
            version: 1,
            body: KafkaListOffsetsRequestEncoder.encodeV1(topics: topics)
        )
        return try KafkaListOffsetsResponseDecoder.decodeV1(response)
    }

    func fetch(
        topics: [KafkaFetchRequestTopic],
        maximumWaitMilliseconds: Int32 = 250,
        broker: KafkaBrokerAddress? = nil
    ) async throws -> KafkaFetchResponse {
        if let broker {
            if connectedAddress != broker || !isConnected() {
                close()
                try await connect(to: broker)
            }
        } else if !isConnected() {
            try await connect()
        }
        guard !topics.isEmpty else {
            return KafkaFetchResponse(
                correlationID: 0,
                throttleTimeMilliseconds: nil,
                topics: []
            )
        }
        var body = KafkaEncoder()
        body.int32(-1) // replica_id: ordinary consumer
        body.int32(maximumWaitMilliseconds)
        body.int32(1) // min_bytes
        body.arrayCount(topics.count)
        for topic in topics {
            body.string(topic.name)
            body.arrayCount(topic.partitions.count)
            for partition in topic.partitions {
                body.int32(partition.partition)
                body.int64(partition.offset)
                body.int32(partition.maximumBytes)
            }
        }
        let response = try await request(
            apiKey: 1,
            version: 0,
            body: body.data
        )
        return try KafkaFetchResponseDecoder.decode(response)
    }

    private func authenticateIfNeeded() async throws {
        guard configuration.username == nil || configuration.saslMechanism == .plain else {
            throw KafkaError.invalidConfiguration("SCRAM requires the librdkafka client")
        }
        guard let username = configuration.username else { return }
        var handshake = KafkaEncoder()
        handshake.string("PLAIN")
        let handshakeResponse = try await request(
            apiKey: 17,
            version: 0,
            body: handshake.data
        )
        let handshakeResult = try KafkaSASLResponseDecoder.decodeHandshake(handshakeResponse)
        guard handshakeResult.errorCode == 0 else {
            throw KafkaError.protocolError(
                code: handshakeResult.errorCode,
                message: "SASL/PLAIN handshake"
            )
        }
        guard handshakeResult.mechanisms.contains("PLAIN") else {
            throw KafkaError.unsupportedAuthentication
        }

        var authenticate = KafkaEncoder()
        let password = configuration.password ?? ""
        authenticate.bytes(Data("\u{0}\(username)\u{0}\(password)".utf8))
        let authenticateResponse = try await request(
            apiKey: 36,
            version: 0,
            body: authenticate.data
        )
        let authenticateResult = try KafkaSASLResponseDecoder.decodeAuthenticate(
            authenticateResponse
        )
        guard authenticateResult.errorCode == 0 else {
            throw KafkaError.protocolError(
                code: authenticateResult.errorCode,
                message: authenticateResult.errorMessage ?? "SASL/PLAIN authentication"
            )
        }
    }

    private func connect(to address: KafkaBrokerAddress) async throws {
        let candidate = try makeConnection(to: address)
        do {
            try await waitUntilReady(candidate)
        } catch {
            candidate.cancel()
            throw error
        }
        connection = candidate
        connectedAddress = address
        do {
            try await authenticateIfNeeded()
        } catch {
            candidate.cancel()
            connection = nil
            connectedAddress = nil
            throw error
        }
    }

    private func request(
        apiKey: Int16,
        version: Int16,
        body: Data
    ) async throws -> Data {
        guard connection != nil else { throw WorkspaceSessionError.notConnected }
        let correlationID = nextCorrelationID
        nextCorrelationID &+= 1

        do {
            try await send(KafkaRequestFrame.make(
                apiKey: apiKey,
                version: version,
                correlationID: correlationID,
                clientID: "QueryCraft",
                body: body
            ))

            let lengthData = try await receiveExactly(4)
            var lengthDecoder = KafkaDecoder(data: lengthData)
            let responseLength = try lengthDecoder.int32()
            guard responseLength >= 4,
                  responseLength <= Self.maximumFrameLength
            else {
                throw KafkaError.invalidResponse
            }
            let response = try await receiveExactly(Int(responseLength))
            var responseDecoder = KafkaDecoder(data: response)
            let actualCorrelationID = try responseDecoder.int32()
            guard actualCorrelationID == correlationID else {
                throw KafkaError.protocolError(
                    code: -1,
                    message: "correlation id mismatch"
                )
            }
            return response
        } catch {
            // A framed request cannot be safely retried on the same socket:
            // the peer may have consumed the request or left partial bytes in
            // the receive buffer. Drop the socket so the session can reconnect
            // through its normal connection lifecycle.
            invalidateConnection()
            throw error
        }
    }

    private func makeConnection(to address: KafkaBrokerAddress) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: UInt16(address.port)) else {
            throw KafkaError.invalidConfiguration("invalid broker port")
        }
        let parameters: NWParameters
        switch configuration.tlsMode {
        case .disabled:
            parameters = .tcp
        case .required, .verifyCA, .verifyIdentity:
            let tlsOptions = NWProtocolTLS.Options()
            configureTLSVerification(
                tlsOptions,
                mode: configuration.tlsMode,
                host: address.host
            )
            parameters = NWParameters(
                tls: tlsOptions,
                tcp: NWProtocolTCP.Options()
            )
        }
        return NWConnection(
            host: NWEndpoint.Host(address.host),
            port: port,
            using: parameters
        )
    }

    private func invalidateConnection() {
        let connection = self.connection
        self.connection = nil
        connectedAddress = nil
        connection?.cancel()
    }

    private func configureTLSVerification(
        _ options: NWProtocolTLS.Options,
        mode: ConnectionTLSMode,
        host: String
    ) {
        let securityOptions = options.securityProtocolOptions
        // Send the broker hostname as SNI so virtual-hosted brokers return
        // the certificate that the configured TLS policy evaluates.
        sec_protocol_options_set_tls_server_name(securityOptions, host)
        sec_protocol_options_set_verify_block(
            securityOptions,
            { _, trustReference, complete in
                guard mode != .required else {
                    // `.required` encrypts the connection but permits private
                    // or self-signed broker certificates, matching the other
                    // drivers' TLS semantics.
                    complete(true)
                    return
                }

                let trust = sec_trust_copy_ref(trustReference).takeRetainedValue()
                let policy: SecPolicy = switch mode {
                case .verifyCA:
                    SecPolicyCreateBasicX509()
                case .verifyIdentity:
                    SecPolicyCreateSSL(true, host as CFString)
                case .disabled, .required:
                    SecPolicyCreateBasicX509()
                }
                guard SecTrustSetPolicies(trust, policy) == errSecSuccess else {
                    complete(false)
                    return
                }
                complete(SecTrustEvaluateWithError(trust, nil))
            },
            queue
        )
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let state = ReadyContinuation(continuation: continuation)
            connection.stateUpdateHandler = { stateUpdate in
                switch stateUpdate {
                case .ready:
                    state.resume()
                case .failed(let error):
                    state.fail(KafkaError.network(error.localizedDescription))
                case .cancelled:
                    state.fail(KafkaError.network("connection cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data) async throws {
        guard let connection else { throw WorkspaceSessionError.notConnected }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(
                        throwing: KafkaError.network(error.localizedDescription)
                    )
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw KafkaError.invalidResponse }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let connection else { throw WorkspaceSessionError.notConnected }
            let remaining = count - result.count
            let chunk = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(
                            throwing: KafkaError.network(error.localizedDescription)
                        )
                    } else if let data, !data.isEmpty {
                        guard data.count <= remaining else {
                            continuation.resume(throwing: KafkaError.invalidResponse)
                            return
                        }
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(
                            throwing: KafkaError.network("connection closed")
                        )
                    } else {
                        continuation.resume(throwing: KafkaError.invalidResponse)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }
}

private final class ReadyContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        guard !didResume, let continuation else {
            lock.unlock()
            return
        }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume()
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !didResume, let continuation else {
            lock.unlock()
            return
        }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
