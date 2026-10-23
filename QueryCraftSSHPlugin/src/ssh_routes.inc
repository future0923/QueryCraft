#include "ssh_agent.inc"

EXPORT uint32_t querycraft_ssh_plugin_route_version(void) { return 1; }
static int valid_agent_path(const char *path) {
    return !path || (path[0] == '/' && strlen(path) < sizeof(((struct sockaddr_un *)0)->sun_path));
}
EXPORT int32_t querycraft_ssh_plugin_set_route(qc_ssh_task *t, const qc_ssh_route_options *options) {
    if (!t || t->has_route || !options || options->size != sizeof(*options) || options->hop_count > 4
        || (options->hop_count && !options->hops) || options->scan_host_key > 1 || !valid_agent_path(options->agent_socket)
        || (options->agent_socket && (t->request.private_key_path || t->request.secret))
        || (options->scan_host_key && (t->request.command || t->file.operation))) return QC_SSH_INVALID;
    qc_ssh_task *hops[4] = {0}; char *agent = options->agent_socket ? strdup(options->agent_socket) : NULL;
    int status = options->agent_socket && !agent ? QC_SSH_MEMORY : QC_SSH_OK;
    for (uint32_t i = 0; !status && i < options->hop_count; ++i) {
        const qc_ssh_hop *hop = &options->hops[i];
        if (hop->size != sizeof(*hop) || hop->connection.command || !valid_agent_path(hop->agent_socket)
            || (hop->agent_socket && (hop->connection.private_key_path || hop->connection.secret))) { status = QC_SSH_INVALID; break; }
        hops[i] = querycraft_ssh_plugin_create(&hop->connection);
        if (!hops[i]) { status = QC_SSH_INVALID; break; }
        if (hop->agent_socket && !(hops[i]->agent_socket = strdup(hop->agent_socket))) status = QC_SSH_MEMORY;
    }
    if (status) { free(agent); for (int i = 0; i < 4; ++i) querycraft_ssh_plugin_destroy(hops[i]); return status; }
    t->has_route = 1; t->agent_socket = agent; t->scan_host_key = options->scan_host_key;
    t->hop_count = options->hop_count; memcpy(t->hops, hops, sizeof(hops)); return QC_SSH_OK;
}
typedef struct { LIBSSH2_CHANNEL *upstream; int closed; } route_link;
typedef struct { LIBSSH2_SESSION *sessions[5]; route_link links[5]; uint32_t count; } route_context;
static LIBSSH2_SEND_FUNC(route_send) {
    (void)socket; (void)flags;
    route_link *link = *abstract; if (link->closed) return -EIO;
    ssize_t n = libssh2_channel_write(link->upstream, buffer, length);
    return n == LIBSSH2_ERROR_EAGAIN ? -EAGAIN : n < 0 ? -EIO : n;
}
static LIBSSH2_RECV_FUNC(route_recv) {
    (void)socket; (void)flags;
    route_link *link = *abstract; if (link->closed) return -EIO;
    ssize_t n = libssh2_channel_read(link->upstream, buffer, length);
    if (!n && !libssh2_channel_eof(link->upstream)) return -EAGAIN;
    return n == LIBSSH2_ERROR_EAGAIN ? -EAGAIN : n < 0 ? -EIO : n;
}
static int authenticate_endpoint(qc_ssh_task *t, int fd, LIBSSH2_SESSION *session, const qc_ssh_task *endpoint) {
    const qc_ssh_request *request = &endpoint->request;
    if (endpoint->agent_socket) return authenticate_agent(t, fd, session, request->username, endpoint->agent_socket);
    char *key = NULL; size_t key_size = 0; int status = QC_SSH_OK, rc;
    if (request->private_key_path) { status = read_key_path(t, request->private_key_path, &key, &key_size); if (status) goto done; }
    do {
        if ((status = check(t))) goto done;
        rc = key ? libssh2_userauth_publickey_frommemory(session, request->username, strlen(request->username), NULL, 0, key, key_size, request->secret)
            : libssh2_userauth_password(session, request->username, request->secret ? request->secret : "");
        if (rc == LIBSSH2_ERROR_EAGAIN) { status = wait_socket(t, fd, session); if (status) goto done; }
    } while (rc == LIBSSH2_ERROR_EAGAIN);
    if (rc) status = QC_SSH_AUTH;
done:
    if (key) { qc_ssh_wipe(key, key_size); free(key); }
    return status;
}
static int connect_route(qc_ssh_task *t, route_context *route, int *fd, LIBSSH2_SESSION **result) {
    const qc_ssh_task *first = t->hop_count ? t->hops[0] : t;
    int status = connect_endpoint(t, &first->request, fd); if (status) return status;
    for (uint32_t i = 0; i <= t->hop_count; ++i) {
        const qc_ssh_task *endpoint = i < t->hop_count ? t->hops[i] : t;
        t->diagnostic.endpoint_index = i + 1;
        if (i) diagnostic_phase(t, QC_SSH_PHASE_FORWARDING);
        if ((status = check(t))) return status;
        if (i) {
            diagnostic_phase(t, QC_SSH_PHASE_FORWARDING);
            LIBSSH2_SESSION *previous = route->sessions[i - 1];
            for (;;) {
                route->links[i].upstream = libssh2_channel_direct_tcpip_ex(previous, endpoint->request.host, endpoint->request.port, "127.0.0.1", 0);
                if (route->links[i].upstream) break;
                if (libssh2_session_last_errno(previous) != LIBSSH2_ERROR_EAGAIN) return QC_SSH_CONNECT;
                status = wait_socket(t, *fd, previous); if (status) return status;
            }
        }
        LIBSSH2_SESSION *session = libssh2_session_init(); if (!session) return QC_SSH_MEMORY;
        route->sessions[i] = session; route->count = i + 1;
        if (i) {
            *libssh2_session_abstract(session) = &route->links[i];
            libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, (libssh2_cb_generic *)route_send);
            libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, (libssh2_cb_generic *)route_recv);
        } else t->physical_session = session;
        libssh2_session_set_blocking(session, 0);
        diagnostic_phase(t, QC_SSH_PHASE_HANDSHAKE);
        int rc;
        while ((rc = libssh2_session_handshake(session, *fd)) == LIBSSH2_ERROR_EAGAIN) {
            status = wait_socket(t, *fd, session); if (status) return status;
        }
        if (rc) return QC_SSH_CONNECT;
        diagnostic_phase(t, QC_SSH_PHASE_HOST_KEY);
        if (i == t->hop_count && t->scan_host_key) {
            char fingerprint[51];
            if (!fingerprint_value(session, fingerprint)) return QC_SSH_HOST_KEY;
            return collect(t, 0, fingerprint, strlen(fingerprint));
        }
        if (!fingerprint_matches(session, endpoint->request.host_fingerprint)) return QC_SSH_HOST_KEY;
        diagnostic_phase(t, QC_SSH_PHASE_AUTHENTICATION);
        status = authenticate_endpoint(t, *fd, session, endpoint); if (status) return status;
        *result = session;
    }
    return QC_SSH_OK;
}
static void close_route(qc_ssh_task *t, route_context *route, int fd) {
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
    for (uint32_t count = route->count; count; --count) {
        uint32_t i = count - 1; route->links[i].closed = 1;
        libssh2_session_set_blocking(route->sessions[i], 1);
        libssh2_session_set_timeout(route->sessions[i], 100);
        libssh2_session_free(route->sessions[i]);
        /* Upstream channels are owned and freed by their parent session. */
    }
    t->physical_session = NULL;
    if (fd >= 0) close(fd);
}
