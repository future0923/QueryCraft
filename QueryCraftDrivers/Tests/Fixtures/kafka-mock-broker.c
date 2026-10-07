// Ephemeral localhost Kafka fixture backed by librdkafka's mock protocol server.
// No credentials, external brokers, or persistent topics are used.
#include <librdkafka/rdkafka.h>
#include <librdkafka/rdkafka_mock.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static void stop(int signal_number) { (void)signal_number; running = 0; }

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char error[512];
    rd_kafka_conf_t *conf = rd_kafka_conf_new();
    rd_kafka_t *owner = rd_kafka_new(RD_KAFKA_PRODUCER, conf, error, sizeof(error));
    if (!owner) { fprintf(stderr, "%s\n", error); return 1; }
    rd_kafka_mock_cluster_t *cluster = rd_kafka_mock_cluster_new(owner, 1);
    if (!cluster) return 1;
    const char *bootstrap = rd_kafka_mock_cluster_bootstraps(cluster);
    if (rd_kafka_mock_topic_create(cluster, "qc-navigation", 2, 1) ||
        rd_kafka_mock_topic_create(cluster, "qc-empty", 1, 1) ||
        rd_kafka_mock_topic_create(cluster, "qc-live", 1, 1) ||
        rd_kafka_mock_topic_create(cluster, "qc-produce", 2, 1)) return 1;
    conf = rd_kafka_conf_new();
    rd_kafka_conf_set(conf, "bootstrap.servers", bootstrap, error, sizeof(error));
    rd_kafka_t *producer = rd_kafka_new(RD_KAFKA_PRODUCER, conf, error, sizeof(error));
    if (!producer) return 1;
    for (int partition = 0; partition < 2; partition++) {
        for (int offset = 0; offset < 10; offset++) {
            char value[80];
            snprintf(value, sizeof(value), "{\"partition\":%d,\"sequence\":%d}", partition, offset);
            rd_kafka_resp_err_t result = rd_kafka_producev(producer,
                RD_KAFKA_V_TOPIC("qc-navigation"), RD_KAFKA_V_PARTITION(partition),
                RD_KAFKA_V_MSGFLAGS(RD_KAFKA_MSG_F_COPY),
                RD_KAFKA_V_VALUE(value, strlen(value)),
                RD_KAFKA_V_TIMESTAMP((int64_t)1700000000000LL + offset * 1000), RD_KAFKA_V_END);
            if (result) return 1;
        }
    }
    if (rd_kafka_flush(producer, 10000)) return 1;
    // Seed committed positions on this ephemeral broker for read-only lag tests.
    conf = rd_kafka_conf_new();
    rd_kafka_conf_set(conf, "bootstrap.servers", bootstrap, error, sizeof(error));
    rd_kafka_conf_set(conf, "group.id", "qc-lag", error, sizeof(error));
    rd_kafka_conf_set(conf, "enable.auto.commit", "false", error, sizeof(error));
    rd_kafka_t *consumer = rd_kafka_new(RD_KAFKA_CONSUMER, conf, error, sizeof(error));
    if (!consumer) return 1;
    rd_kafka_topic_partition_list_t *positions = rd_kafka_topic_partition_list_new(2);
    rd_kafka_topic_partition_list_add(positions, "qc-navigation", 0)->offset = 3;
    rd_kafka_topic_partition_list_add(positions, "qc-navigation", 1)->offset = 7;
    if (rd_kafka_commit(consumer, positions, 0)) return 1;
    rd_kafka_topic_partition_list_destroy(positions);
    rd_kafka_destroy_flags(consumer, RD_KAFKA_DESTROY_F_NO_CONSUMER_CLOSE);
    // Exercise a cold fetch that cannot assume metadata/assignment is ready in 1 second.
    rd_kafka_mock_broker_set_rtt(cluster, -1, 250);
    FILE *ready = fopen(argv[1], "w");
    if (!ready) return 1;
    fprintf(ready, "%s", bootstrap);
    fclose(ready);
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    while (running) sleep(1);
    rd_kafka_destroy(producer);
    rd_kafka_mock_cluster_destroy(cluster);
    rd_kafka_destroy(owner);
    return 0;
}
