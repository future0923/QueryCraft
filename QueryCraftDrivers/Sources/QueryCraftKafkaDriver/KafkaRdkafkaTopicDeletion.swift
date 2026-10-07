import Foundation
import CRdkafka
import QueryCraftFeature

extension KafkaRdkafkaClient {
    func deleteTopic(name: String) throws {
        try WorkspaceKafkaTopicDeletionRequest(topic: name).validate()
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard let topic = rd_kafka_DeleteTopic_new(name) else {
            throw WorkspaceKafkaTopicDeletionError.notSent("Could not allocate topic deletion request")
        }
        defer { rd_kafka_DeleteTopic_destroy(topic) }
        do {
            try withAdminEvent(operation: RD_KAFKA_ADMIN_OP_DELETETOPICS,
                               observesCancellationAfterSubmission: false, operationTimeoutMilliseconds: 8_000) { options, queue in
                var topics: [OpaquePointer?] = [topic]
                topics.withUnsafeMutableBufferPointer {
                    rd_kafka_DeleteTopics(handle, $0.baseAddress, 1, options, queue)
                }
            } decode: { event in
                guard let result = rd_kafka_event_DeleteTopics_result(event) else {
                    throw KafkaError.network("Missing topic deletion result")
                }
                var count = 0
                guard let results = rd_kafka_DeleteTopics_result_topics(result, &count), count == 1,
                      let result = results[0], let resultName = rd_kafka_topic_result_name(result),
                      String(cString: resultName) == name else {
                    throw KafkaError.network("Topic deletion response does not match the requested topic")
                }
                let error = rd_kafka_topic_result_error(result)
                // A stale sidebar entry for an already absent topic is reconciled too.
                let message = rd_kafka_topic_result_error_string(result).map { String(cString: $0) }
                    ?? String(cString: rd_kafka_err2str(error))
                try Self.validateTopicDeletionResult(error: error, message: message)
            }
        } catch let error as WorkspaceKafkaTopicDeletionError {
            throw error
        } catch {
            // Admin timeouts may follow an accepted write. Do not automatically retry.
            throw WorkspaceKafkaTopicDeletionError.unconfirmed(error.localizedDescription)
        }
    }

    static func validateTopicDeletionResult(error: rd_kafka_resp_err_t, message: String) throws {
        if error == RD_KAFKA_RESP_ERR_NO_ERROR || error == RD_KAFKA_RESP_ERR_UNKNOWN_TOPIC_OR_PART { return }
        if [RD_KAFKA_RESP_ERR_TOPIC_AUTHORIZATION_FAILED, RD_KAFKA_RESP_ERR_CLUSTER_AUTHORIZATION_FAILED,
            RD_KAFKA_RESP_ERR_TOPIC_EXCEPTION, RD_KAFKA_RESP_ERR_INVALID_REQUEST,
            RD_KAFKA_RESP_ERR_TOPIC_DELETION_DISABLED, RD_KAFKA_RESP_ERR_POLICY_VIOLATION,
            RD_KAFKA_RESP_ERR_UNSUPPORTED_VERSION].contains(error) {
            throw WorkspaceKafkaTopicDeletionError.rejected(message)
        }
        throw WorkspaceKafkaTopicDeletionError.unconfirmed(message)
    }
}
