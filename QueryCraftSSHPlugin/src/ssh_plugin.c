#include "QueryCraftSSHPlugin.h"
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))
struct qc_ssh_task {
    qc_ssh_request request;
    atomic_bool cancelled;
    qc_ssh_result result;
    double deadline;
    qc_ssh_file_request file;
    int session_reusable;
    qc_ssh_progress_callback progress;
    void *progress_context;
    int has_route, scan_host_key;
    char *agent_socket;
    struct qc_ssh_task *hops[4];
    uint32_t hop_count;
    LIBSSH2_SESSION *physical_session;
    qc_ssh_diagnostic diagnostic;
};
EXPORT uint32_t querycraft_ssh_plugin_diagnostic_version(void) { return 1; }
EXPORT const qc_ssh_diagnostic *querycraft_ssh_plugin_diagnostic(qc_ssh_task *t) { return t ? &t->diagnostic : NULL; }
static void diagnostic_phase(qc_ssh_task *t, uint32_t phase) { t->diagnostic.phase = phase; }
EXPORT uint32_t querycraft_ssh_plugin_progress_version(void) { return 1; }
EXPORT void querycraft_ssh_plugin_set_progress(qc_ssh_task *t, qc_ssh_progress_callback callback, void *context) {
    if (t) { t->progress = callback; t->progress_context = context; }
}
static void transfer_progress(qc_ssh_task *t, uint32_t phase, uint64_t bytes, uint64_t total, int known) {
    if (t->progress) {
        qc_ssh_progress value = {sizeof(qc_ssh_progress), phase, bytes, total, known && bytes <= total};
        t->progress(t->progress_context, &value);
    }
}
static pthread_once_t initialization = PTHREAD_ONCE_INIT;
static int initialization_status;
static void initialize(void) { initialization_status = libssh2_init(0); }
static double monotonic_time(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1000000000.0;
}
static int check(qc_ssh_task *t) {
    if (atomic_load(&t->cancelled)) return QC_SSH_CANCELLED;
    if (monotonic_time() >= t->deadline) return QC_SSH_TIMEOUT;
    return QC_SSH_OK;
}
static int wait_socket(qc_ssh_task *t, int fd, LIBSSH2_SESSION *session) {
    int status = check(t); if (status) return status;
    short events = POLLIN | POLLOUT;
    if (t->physical_session) session = t->physical_session;
    if (session) {
        int directions = libssh2_session_block_directions(session);
        if (directions) events = ((directions & LIBSSH2_SESSION_BLOCK_INBOUND) ? POLLIN : 0)
            | ((directions & LIBSSH2_SESSION_BLOCK_OUTBOUND) ? POLLOUT : 0);
    }
    struct pollfd p = {fd, events, 0};
    int rc = poll(&p, 1, 50);
    if (rc < 0 && errno != EINTR) return QC_SSH_IO;
    if (p.revents & POLLNVAL) return QC_SSH_IO;
    return check(t);
}

/* A system resolver can block outside our deadline. Bound both caller waiting
   time and outstanding resolver workers; ownership survives timeout/cancel. */
typedef struct {
    atomic_int references;
    pthread_mutex_t mutex;
    char *host, port[6];
    struct addrinfo *addresses;
    int finished, error;
} resolver;
static atomic_int resolvers;
static void release_resolver(resolver *r) {
    if (atomic_fetch_sub(&r->references, 1) == 1) {
        if (r->addresses) freeaddrinfo(r->addresses);
        pthread_mutex_destroy(&r->mutex); free(r->host); free(r);
    }
}
static void *resolve_host(void *context) {
    resolver *r = context;
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    int error = getaddrinfo(r->host, r->port, &hints, &addresses);
    pthread_mutex_lock(&r->mutex);
    r->addresses = addresses; r->error = error; r->finished = 1;
    pthread_mutex_unlock(&r->mutex);
    atomic_fetch_sub(&resolvers, 1); release_resolver(r); return NULL;
}
static int resolve(qc_ssh_task *t, const qc_ssh_request *request, struct addrinfo **addresses) {
    if (atomic_fetch_add(&resolvers, 1) >= 4) {
        atomic_fetch_sub(&resolvers, 1); return QC_SSH_CAPACITY;
    }
    resolver *r = calloc(1, sizeof(*r));
    if (!r) { atomic_fetch_sub(&resolvers, 1); return QC_SSH_MEMORY; }
    atomic_init(&r->references, 2); pthread_mutex_init(&r->mutex, NULL);
    r->host = strdup(request->host);
    snprintf(r->port, sizeof(r->port), "%u", request->port);
    pthread_t thread;
    if (!r->host || pthread_create(&thread, NULL, resolve_host, r)) {
        atomic_fetch_sub(&resolvers, 1); release_resolver(r); release_resolver(r); return QC_SSH_CONNECT;
    }
    pthread_detach(thread);
    int status = 0;
    for (;;) {
        status = check(t); if (status) break;
        pthread_mutex_lock(&r->mutex);
        int done = r->finished;
        if (done) {
            status = r->error ? QC_SSH_CONNECT : QC_SSH_OK;
            *addresses = r->addresses; r->addresses = NULL;
        }
        pthread_mutex_unlock(&r->mutex);
        if (done) break;
        struct timespec pause = {0, 20000000}; nanosleep(&pause, NULL);
    }
    release_resolver(r); return status;
}
static int connect_endpoint(qc_ssh_task *t, const qc_ssh_request *request, int *connected) {
    struct addrinfo *addresses = NULL;
    diagnostic_phase(t, QC_SSH_PHASE_RESOLVE);
    int status = resolve(t, request, &addresses);
    if (status) return status;
    diagnostic_phase(t, QC_SSH_PHASE_CONNECT);
    status = QC_SSH_CONNECT;
    for (struct addrinfo *a = addresses; a; a = a->ai_next) {
        if ((status = check(t))) break;
        status = QC_SSH_CONNECT;
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        int flags = fcntl(fd, F_GETFL, 0), yes = 1;
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); continue; }
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        int rc = connect(fd, a->ai_addr, a->ai_addrlen);
        if (rc == 0) status = QC_SSH_OK;
        if (rc < 0 && errno == EINPROGRESS) {
            do {
                status = wait_socket(t, fd, NULL); if (status) break;
                int error = 0; socklen_t length = sizeof(error);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0 || error) { rc = -1; break; }
                struct pollfd p = {fd, POLLOUT, 0};
                if (poll(&p, 1, 0) > 0) { rc = 0; break; }
            } while (1);
        }
        if (!status && rc == 0) { *connected = fd; break; }
        close(fd);
        if (status == QC_SSH_CANCELLED || status == QC_SSH_TIMEOUT) break;
        status = QC_SSH_CONNECT;
    }
    if (addresses) freeaddrinfo(addresses);
    return status;
}
static int fingerprint_value(LIBSSH2_SESSION *s, char actual[51]) {
    const unsigned char *hash = (const unsigned char *)libssh2_hostkey_hash(s, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (!hash) return 0;
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    memcpy(actual, "SHA256:", 7);
    size_t at = 7;
    for (size_t i = 0; i < 32; i += 3) {
        unsigned v = (unsigned)hash[i] << 16;
        if (i + 1 < 32) v |= (unsigned)hash[i + 1] << 8;
        if (i + 2 < 32) v |= hash[i + 2];
        actual[at++] = alphabet[(v >> 18) & 63]; actual[at++] = alphabet[(v >> 12) & 63];
        if (i + 1 < 32) actual[at++] = alphabet[(v >> 6) & 63];
        if (i + 2 < 32) actual[at++] = alphabet[v & 63];
    }
    actual[at] = 0;
    return 1;
}
static int fingerprint_matches(LIBSSH2_SESSION *s, const char *expected) {
    char actual[51]; return fingerprint_value(s, actual) && strcmp(actual, expected) == 0;
}
static int read_key_path(qc_ssh_task *t, const char *path, char **bytes, size_t *length) {
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) return QC_SSH_AUTH;
    struct stat metadata;
    if (fstat(fd, &metadata) || !S_ISREG(metadata.st_mode) || metadata.st_size < 1 || metadata.st_size > 1048576) {
        close(fd); return QC_SSH_AUTH;
    }
    *length = (size_t)metadata.st_size;
    *bytes = calloc(*length + 1, 1);
    if (!*bytes) { close(fd); return QC_SSH_MEMORY; }
    size_t offset = 0;
    int status = 0;
    while (offset < *length) {
        if ((status = check(t))) break;
        ssize_t count = read(fd, *bytes + offset, *length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { status = QC_SSH_AUTH; break; }
        offset += (size_t)count;
    }
    close(fd); return status;
}
static int read_private_key(qc_ssh_task *t, char **bytes, size_t *length) {
    return read_key_path(t, t->request.private_key_path, bytes, length);
}
static int collect(qc_ssh_task *t, int stream, const char *bytes, size_t length) {
    qc_ssh_result *r = &t->result;
    size_t used = r->stdout_length + r->stderr_length;
    size_t keep = t->request.maximum_output_bytes - used;
    if (keep > length) keep = length;
    r->output_bytes += length; if (keep < length) r->truncated = 1;
    if (!keep) return 0;
    const unsigned char **data = stream ? &r->stderr_data : &r->stdout_data;
    size_t *size = stream ? &r->stderr_length : &r->stdout_length;
    unsigned char *buffer = realloc((void *)*data, *size + keep);
    if (!buffer) return QC_SSH_MEMORY;
    memcpy(buffer + *size, bytes, keep); *size += keep; *data = buffer; return 0;
}

EXPORT uint32_t querycraft_ssh_plugin_version(void) { return QC_SSH_ABI_VERSION; }
EXPORT void querycraft_ssh_plugin_destroy(qc_ssh_task *t);
EXPORT qc_ssh_task *querycraft_ssh_plugin_create(const qc_ssh_request *request) {
    if (!request || request->size != sizeof(*request) || !request->host || !request->username
        || !request->host_fingerprint || !request->port || !request->timeout_ms
        || request->timeout_ms > 300000 || !request->maximum_output_bytes
        || request->maximum_output_bytes > 1048576) return NULL;
    qc_ssh_task *t = calloc(1, sizeof(*t)); if (!t) return NULL;
    atomic_init(&t->cancelled, 0); t->request = *request;
    t->request.host = strdup(request->host); t->request.username = strdup(request->username);
    t->request.host_fingerprint = strdup(request->host_fingerprint);
    t->request.private_key_path = request->private_key_path ? strdup(request->private_key_path) : NULL;
    t->request.secret = request->secret ? strdup(request->secret) : NULL;
    t->request.command = request->command ? strdup(request->command) : NULL;
    if (!t->request.host || !t->request.username || !t->request.host_fingerprint
        || (request->private_key_path && !t->request.private_key_path)
        || (request->secret && !t->request.secret) || (request->command && !t->request.command)) {
        free((void *)t->request.host); free((void *)t->request.username); free((void *)t->request.host_fingerprint);
        free((void *)t->request.private_key_path); free((void *)t->request.secret); free((void *)t->request.command); free(t); return NULL;
    }
    t->result.size = sizeof(t->result); t->result.exit_status = -1; t->session_reusable = 1; return t;
}
EXPORT uint32_t querycraft_ssh_plugin_file_version(void) { return QC_SSH_FILE_ABI_VERSION; }
EXPORT uint32_t querycraft_ssh_plugin_file_management_version(void) { return 1; }
EXPORT qc_ssh_task *querycraft_ssh_plugin_file_create(const qc_ssh_file_request *r) {
    if (!r || r->size != sizeof(*r) || r->operation < 1 || r->operation > 9 || r->connection.command
        || !r->remote_path || r->remote_path[0] != '/' || strlen(r->remote_path) > 4096
        || r->maximum_entries > 500 || r->offset > 9007199254740991ULL
        || r->maximum_transfer_bytes > 1073741824ULL || r->overwrite > 1
        || ((r->operation == 4 || r->operation == 5) && (!r->maximum_transfer_bytes || !r->local_path || r->local_path[0] != '/'))
        || (r->operation == 4 && (!r->temporary_path || r->temporary_path[0] != '/' || !strcmp(r->temporary_path, r->remote_path)))) return NULL;
    if ((r->local_path && strlen(r->local_path) > 4096) || (r->temporary_path && strlen(r->temporary_path) > 4096)
        || (r->operation == QC_SSH_FILE_MOVE && (!r->temporary_path || r->temporary_path[0] != '/' || !strcmp(r->temporary_path, r->remote_path)))) return NULL;
    qc_ssh_task *t = querycraft_ssh_plugin_create(&r->connection); if (!t) return NULL;
    t->file = *r;
    t->file.remote_path = strdup(r->remote_path);
    t->file.local_path = r->local_path ? strdup(r->local_path) : NULL;
    t->file.temporary_path = r->temporary_path ? strdup(r->temporary_path) : NULL;
    if (!t->file.remote_path || (r->local_path && !t->file.local_path) || (r->temporary_path && !t->file.temporary_path)) {
        querycraft_ssh_plugin_destroy(t); return NULL;
    }
    return t;
}
#include "ssh_files.inc"
#include "ssh_pool.inc"
#include "ssh_routes.inc"
static const qc_ssh_result *run_task(qc_ssh_task *t, qc_ssh_pool *pool, const char *scope) {
    int fd = -1, rc, status = QC_SSH_OK, slot = -1;
    route_context route = {0};
    if (t->has_route) pool = NULL;
    char *key_bytes = NULL; size_t key_length = 0;
    LIBSSH2_SESSION *session = NULL; LIBSSH2_CHANNEL *channel = NULL;
    t->deadline = monotonic_time() + t->request.timeout_ms / 1000.0;
    t->diagnostic = (qc_ssh_diagnostic){sizeof(qc_ssh_diagnostic), 1, t->hop_count, QC_SSH_PHASE_PREPARING};
    pthread_once(&initialization, initialize);
    if (initialization_status) { status = QC_SSH_IO; goto done; }
    if ((status = check(t))) goto done;
    if (t->has_route) {
        status = connect_route(t, &route, &fd, &session);
        if (status || t->scan_host_key) goto done;
        goto authenticated;
    }
    if (pool) {
        if (!scope || !*scope || strlen(scope) > 128) { status = QC_SSH_INVALID; goto done; }
        unsigned char binding[32];
        diagnostic_phase(t, QC_SSH_PHASE_AUTHENTICATION);
        status = pool_binding(pool, t, scope, &key_bytes, &key_length, binding);
        if (status) { querycraft_ssh_plugin_pool_invalidate(pool, scope); goto done; }
        diagnostic_phase(t, QC_SSH_PHASE_POOL);
        status = checkout(pool, scope, binding, &slot, &fd, &session);
        qc_ssh_wipe(binding, sizeof(binding));
        if (status) goto done;
        if (session) goto authenticated;
    }
    status = connect_endpoint(t, &t->request, &fd); if (status) goto done;
    session = libssh2_session_init(); if (!session) { status = QC_SSH_MEMORY; goto done; }
    libssh2_session_set_blocking(session, 0);
    diagnostic_phase(t, QC_SSH_PHASE_HANDSHAKE);
    while ((rc = libssh2_session_handshake(session, fd)) == LIBSSH2_ERROR_EAGAIN) {
        status = wait_socket(t, fd, session); if (status) goto done;
    }
    if (rc) { status = QC_SSH_CONNECT; goto done; }
    diagnostic_phase(t, QC_SSH_PHASE_HOST_KEY);
    if (!fingerprint_matches(session, t->request.host_fingerprint)) { status = QC_SSH_HOST_KEY; goto done; }
    diagnostic_phase(t, QC_SSH_PHASE_AUTHENTICATION);
    if (t->request.private_key_path && !key_bytes) {
        status = read_private_key(t, &key_bytes, &key_length); if (status) goto done;
    }
    do {
        if ((status = check(t))) goto done;
        if (t->request.private_key_path) {
            rc = libssh2_userauth_publickey_frommemory(session, t->request.username, strlen(t->request.username),
                NULL, 0, key_bytes, key_length, t->request.secret);
        } else {
            rc = libssh2_userauth_password(session, t->request.username, t->request.secret ? t->request.secret : "");
        }
        if (rc == LIBSSH2_ERROR_EAGAIN) { status = wait_socket(t, fd, session); if (status) goto done; }
    } while (rc == LIBSSH2_ERROR_EAGAIN);
    if (rc) { status = QC_SSH_AUTH; goto done; }
authenticated:
    if (t->file.operation || t->request.command) diagnostic_phase(t, t->file.operation ? QC_SSH_PHASE_SFTP : QC_SSH_PHASE_COMMAND);
    if ((status = check(t))) goto done;
    if (t->file.operation) { status = run_file(t, fd, session); goto done; }
    if (!t->request.command) goto done;
    do {
        if ((status = check(t))) goto done;
        channel = libssh2_channel_open_session(session);
        if (channel) break;
        if (libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN) { status = QC_SSH_IO; goto done; }
        status = wait_socket(t, fd, session); if (status) goto done;
    } while (1);
    t->result.command_may_have_run = 1;
    while ((rc = libssh2_channel_exec(channel, t->request.command)) == LIBSSH2_ERROR_EAGAIN) {
        status = wait_socket(t, fd, session); if (status) goto done;
    }
    if (rc) { status = QC_SSH_IO; goto done; }
    while ((rc = libssh2_channel_send_eof(channel)) == LIBSSH2_ERROR_EAGAIN) {
        status = wait_socket(t, fd, session); if (status) goto done;
    }
    if (rc) { status = QC_SSH_IO; goto done; }
    for (;;) {
        if ((status = check(t))) goto done;
        int progress = 0;
        for (int stream = 0; stream < 2; ++stream) {
            char buffer[16384];
            ssize_t count = libssh2_channel_read_ex(channel, stream, buffer, sizeof(buffer));
            if (count > 0) { progress = 1; status = collect(t, stream, buffer, (size_t)count); if (status) goto done; }
            else if (count < 0 && count != LIBSSH2_ERROR_EAGAIN) { status = QC_SSH_IO; goto done; }
        }
        if (!progress && libssh2_channel_eof(channel)) break;
        if (!progress) { status = wait_socket(t, fd, session); if (status) goto done; }
    }
    while ((rc = libssh2_channel_close(channel)) == LIBSSH2_ERROR_EAGAIN) {
        status = wait_socket(t, fd, session); if (status) goto done;
    }
    if (rc) { status = QC_SSH_IO; goto done; }
    char *signal = NULL;
    rc = libssh2_channel_get_exit_signal(channel, &signal, NULL, NULL, NULL, NULL, NULL);
    if (rc || signal) {
        if (signal) libssh2_free(session, signal);
        status = QC_SSH_IO; goto done;
    }
    t->result.exit_status = libssh2_channel_get_exit_status(channel);
    while ((rc = libssh2_channel_free(channel)) == LIBSSH2_ERROR_EAGAIN) {
        status = wait_socket(t, fd, session); if (status) goto done;
    }
    if (rc) { status = QC_SSH_IO; goto done; }
    channel = NULL;
done:
    if (key_bytes) { qc_ssh_wipe(key_bytes, key_length); free(key_bytes); }
    if (t->has_route) close_route(t, &route, fd);
    else if (pool && slot >= 0) checkin(pool, slot, fd, session, !status && t->session_reusable && !check(t));
    else close_session(fd, session);
    t->result.status = status; return &t->result;
}
EXPORT const qc_ssh_result *querycraft_ssh_plugin_run(qc_ssh_task *t) { return run_task(t, NULL, NULL); }
EXPORT const qc_ssh_result *querycraft_ssh_plugin_pool_run(qc_ssh_pool *pool, qc_ssh_task *t, const char *scope) {
    if (!pool || !t) return NULL;
    return run_task(t, pool, scope);
}
EXPORT void querycraft_ssh_plugin_cancel(qc_ssh_task *t) { atomic_store(&t->cancelled, 1); }
EXPORT void querycraft_ssh_plugin_destroy(qc_ssh_task *t) {
    if (!t) return;
    free((void *)t->request.host); free((void *)t->request.username); free((void *)t->request.host_fingerprint);
    free((void *)t->request.private_key_path);
    if (t->request.secret) { qc_ssh_wipe((void *)t->request.secret, strlen(t->request.secret)); free((void *)t->request.secret); }
    free((void *)t->file.remote_path); free((void *)t->file.local_path); free((void *)t->file.temporary_path);
    free(t->agent_socket);
    for (uint32_t i = 0; i < t->hop_count; ++i) querycraft_ssh_plugin_destroy(t->hops[i]);
    free((void *)t->request.command); free((void *)t->result.stdout_data); free((void *)t->result.stderr_data); free(t);
}
