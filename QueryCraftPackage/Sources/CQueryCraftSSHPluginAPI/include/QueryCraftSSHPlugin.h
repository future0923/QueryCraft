#ifndef QUERYCRAFT_SSH_PLUGIN_H
#define QUERYCRAFT_SSH_PLUGIN_H
#include <stddef.h>
#include <stdint.h>

/* Independent plugin ABI. No Swift metadata or database-driver ABI crosses it. */
#define QC_SSH_ABI_VERSION 1
static inline void qc_ssh_wipe(void *memory, size_t length) {
    volatile unsigned char *bytes = (volatile unsigned char *)memory;
    while (length--) *bytes++ = 0;
}
typedef struct qc_ssh_task qc_ssh_task;
typedef struct {
    uint32_t size;
    const char *host;
    uint16_t port;
    const char *username;
    const char *host_fingerprint; /* OpenSSH SHA256:base64, without padding */
    const char *private_key_path; /* NULL selects password authentication */
    const char *secret; /* password or private-key passphrase; copied by create */
    const char *command; /* NULL tests authenticated connectivity only */
    uint32_t timeout_ms;
    uint32_t maximum_output_bytes; /* combined stdout + stderr; drain after cap */
} qc_ssh_request;

enum {
    QC_SSH_OK = 0, QC_SSH_INVALID = 1, QC_SSH_CONNECT = 2,
    QC_SSH_HOST_KEY = 3, QC_SSH_AUTH = 4, QC_SSH_TIMEOUT = 5,
    QC_SSH_CANCELLED = 6, QC_SSH_IO = 7, QC_SSH_MEMORY = 8,
    QC_SSH_CAPACITY = 9, QC_SSH_NOT_FOUND = 10, QC_SSH_PERMISSION = 11,
    QC_SSH_EXISTS = 12, QC_SSH_UNSUPPORTED = 13, QC_SSH_LIMIT = 14,
    QC_SSH_CHANGED = 15, QC_SSH_LOCAL_IO = 16, QC_SSH_AGENT = 17
};
typedef struct {
    uint32_t size;
    int32_t status;
    int32_t exit_status;
    uint8_t command_may_have_run;
    uint8_t truncated;
    const unsigned char *stdout_data;
    size_t stdout_length;
    const unsigned char *stderr_data;
    size_t stderr_length;
    uint64_t output_bytes;
} qc_ssh_result;

/* create copies all strings; run is called once; cancel may run concurrently.
   Result pointers live until destroy. destroy is called after run/cancel finish. */
typedef uint32_t (*qc_ssh_version_fn)(void);
typedef qc_ssh_task *(*qc_ssh_create_fn)(const qc_ssh_request *);
typedef const qc_ssh_result *(*qc_ssh_run_fn)(qc_ssh_task *);
typedef void (*qc_ssh_cancel_fn)(qc_ssh_task *);
typedef void (*qc_ssh_destroy_fn)(qc_ssh_task *);

/* Optional file extension 1. Base ABI and result layouts remain unchanged.
   stat/list metadata uses base64-name + tab-separated numeric attributes;
   read returns raw stdout bytes, transfers stream through local regular files. */
#define QC_SSH_FILE_ABI_VERSION 1
enum { QC_SSH_FILE_STAT = 1, QC_SSH_FILE_LIST = 2, QC_SSH_FILE_READ = 3,
       QC_SSH_FILE_UPLOAD = 4, QC_SSH_FILE_DOWNLOAD = 5,
       QC_SSH_FILE_MKDIR = 6, QC_SSH_FILE_MOVE = 7, QC_SSH_FILE_UNLINK = 8, QC_SSH_FILE_RMDIR = 9 };
typedef struct {
    uint32_t size;
    qc_ssh_request connection;
    uint32_t operation;
    const char *remote_path;
    const char *local_path;
    const char *temporary_path; /* upload/download staging; MOVE uses this as destination */
    uint64_t offset;
    uint64_t maximum_transfer_bytes;
    uint32_t maximum_entries;
    uint32_t overwrite;
} qc_ssh_file_request;
typedef qc_ssh_task *(*qc_ssh_file_create_fn)(const qc_ssh_file_request *);

/* Optional pool extension 1. Exclusive leases; no concurrent use of a session.
   Scope is a host-owned connection UUID (1..128 bytes). No request is replayed.
   Destroy only after all runs/controls finish; invalidate/prune may overlap run.
   Old run/create entry points retain their one-shot behavior and ABI. */
typedef struct qc_ssh_pool qc_ssh_pool;
typedef qc_ssh_pool *(*qc_ssh_pool_create_fn)(uint32_t maximum, uint32_t idle_ms, uint32_t lifetime_ms);
typedef const qc_ssh_result *(*qc_ssh_pool_run_fn)(qc_ssh_pool *, qc_ssh_task *, const char *scope);
typedef void (*qc_ssh_pool_invalidate_fn)(qc_ssh_pool *, const char *scope);
typedef void (*qc_ssh_pool_control_fn)(qc_ssh_pool *);
/* Optional transfer progress extension 1. Set once before run; callback runs
   synchronously on the task worker, never concurrently, until run returns.
   Does not imply publication or completion. Existing request/result ABI stays 1. */
typedef struct {
    uint32_t size;
    uint32_t phase; /* 1 transferring, 2 verifying, 3 publishing */
    uint64_t transferred;
    uint64_t total;
    uint32_t total_known;
} qc_ssh_progress;
typedef void (*qc_ssh_progress_callback)(void *, const qc_ssh_progress *);
typedef void (*qc_ssh_set_progress_fn)(qc_ssh_task *, qc_ssh_progress_callback, void *);
/* Optional route extension 1; configure once before run. Inputs are copied.
   Hops are ordered from local first hop to final jump host; maximum four.
   A non-NULL agent_socket selects local agent exclusively (never forwarding).
   scan_host_key returns the target's negotiated fingerprint, without sending
   target credentials. Every jump still requires its own verified pin/auth. */
typedef struct {
    uint32_t size;
    qc_ssh_request connection;
    const char *agent_socket;
} qc_ssh_hop;
typedef struct {
    uint32_t size;
    const char *agent_socket;
    const qc_ssh_hop *hops;
    uint32_t hop_count;
    uint32_t scan_host_key;
} qc_ssh_route_options;
typedef int32_t (*qc_ssh_set_route_fn)(qc_ssh_task *, const qc_ssh_route_options *);
/* Optional diagnostic extension 1. Read only after run returns, before destroy.
   No strings, credentials or protocol error text cross this boundary.
   Endpoint is one-based, target is hop_count+1. Forwarding identifies the
   destination endpoint; its preceding endpoint is the forwarding server. */
enum { QC_SSH_PHASE_PREPARING = 1, QC_SSH_PHASE_RESOLVE = 2,
       QC_SSH_PHASE_CONNECT = 3, QC_SSH_PHASE_HANDSHAKE = 4,
       QC_SSH_PHASE_HOST_KEY = 5, QC_SSH_PHASE_AUTHENTICATION = 6,
       QC_SSH_PHASE_FORWARDING = 7, QC_SSH_PHASE_POOL = 8,
       QC_SSH_PHASE_COMMAND = 9, QC_SSH_PHASE_SFTP = 10 };
typedef struct {
    uint32_t size, endpoint_index, hop_count, phase;
} qc_ssh_diagnostic;
typedef const qc_ssh_diagnostic *(*qc_ssh_diagnostic_fn)(qc_ssh_task *);
#endif
