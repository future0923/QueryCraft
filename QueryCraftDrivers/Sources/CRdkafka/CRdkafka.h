#ifndef CRdkafka_h
#define CRdkafka_h

#include <librdkafka/rdkafka.h>

// Swift cannot call C variadic functions. Header ownership transfers only on success.
static inline rd_kafka_resp_err_t qc_kafka_produce(
    rd_kafka_t *producer, const char *topic, int32_t partition,
    const void *key, size_t key_len, const void *value, size_t value_len,
    rd_kafka_headers_t *headers) {
    return rd_kafka_producev(producer,
        RD_KAFKA_V_TOPIC(topic), RD_KAFKA_V_PARTITION(partition),
        RD_KAFKA_V_MSGFLAGS(RD_KAFKA_MSG_F_COPY),
        RD_KAFKA_V_KEY(key, key_len), RD_KAFKA_V_VALUE((void *)value, value_len),
        RD_KAFKA_V_HEADERS(headers), RD_KAFKA_V_END);
}

#endif /* CRdkafka_h */
