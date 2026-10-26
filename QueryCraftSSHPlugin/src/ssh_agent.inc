/* Local agent IPC. All sockets are nonblocking and all waits share the task's
   deadline/cancellation. No agent/key material is forwarded to any server. */
#define AGENT_LIMIT 1048576U
static uint32_t agent_u32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static void agent_put_u32(unsigned char *p, uint32_t n) {
    p[0] = (unsigned char)(n >> 24); p[1] = (unsigned char)(n >> 16); p[2] = (unsigned char)(n >> 8); p[3] = (unsigned char)n;
}
static int agent_field(const unsigned char **p, size_t *left, const unsigned char **value, size_t *length) {
    if (*left < 4) return 0;
    size_t n = agent_u32(*p); if (n > *left - 4) return 0;
    *value = *p + 4; *length = n; *p += 4 + n; *left -= 4 + n; return 1;
}
static int agent_wait(qc_ssh_task *t, int fd, short events) {
    int status = check(t); if (status) return status;
    struct pollfd p = {fd, events, 0};
    int rc = poll(&p, 1, 50);
    if ((rc < 0 && errno != EINTR) || (p.revents & POLLNVAL)) return QC_SSH_AGENT;
    return check(t);
}
static int agent_connect_socket(qc_ssh_task *t, const char *path, int *result) {
    struct stat metadata; struct sockaddr_un address = {0};
    if (!path || path[0] != '/' || strlen(path) >= sizeof(address.sun_path)
        || stat(path, &metadata) || !S_ISSOCK(metadata.st_mode) || metadata.st_uid != geteuid()) return QC_SSH_AGENT;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return QC_SSH_AGENT;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    if (fcntl(fd, F_SETFL, O_NONBLOCK) || fcntl(fd, F_SETFD, FD_CLOEXEC)) { close(fd); return QC_SSH_AGENT; }
    address.sun_family = AF_UNIX; strcpy(address.sun_path, path);
    int rc = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (rc && errno != EINPROGRESS && errno != EAGAIN && errno != EWOULDBLOCK) { close(fd); return QC_SSH_AGENT; }
    if (rc) {
        for (;;) {
            int status = agent_wait(t, fd, POLLOUT); if (status) { close(fd); return status; }
            struct pollfd p = {fd, POLLOUT, 0};
            if (poll(&p, 1, 0) <= 0) continue;
            int error = 0; socklen_t size = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) || error) { close(fd); return QC_SSH_AGENT; }
            break;
        }
    }
    uid_t uid; gid_t gid;
    if (getpeereid(fd, &uid, &gid) || uid != geteuid()) { close(fd); return QC_SSH_AGENT; }
    *result = fd; return QC_SSH_OK;
}
static int agent_io(qc_ssh_task *t, int fd, unsigned char *buffer, size_t size, int writing) {
    size_t at = 0;
    while (at < size) {
        int status = check(t); if (status) return status;
        ssize_t n = writing ? send(fd, buffer + at, size - at, 0) : recv(fd, buffer + at, size - at, 0);
        if (n > 0) { at += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            status = agent_wait(t, fd, writing ? POLLOUT : POLLIN); if (status) return status;
            continue;
        }
        return QC_SSH_AGENT;
    }
    return QC_SSH_OK;
}
static int agent_exchange(qc_ssh_task *t, int fd, unsigned char *request, size_t size,
                          unsigned char **response, size_t *response_size) {
    if (!size || size > AGENT_LIMIT) return QC_SSH_AGENT;
    unsigned char length[4]; agent_put_u32(length, (uint32_t)size);
    int status = agent_io(t, fd, length, 4, 1);
    if (!status) status = agent_io(t, fd, request, size, 1);
    if (!status) status = agent_io(t, fd, length, 4, 0);
    if (status) return status;
    *response_size = agent_u32(length);
    if (!*response_size || *response_size > AGENT_LIMIT) return QC_SSH_AGENT;
    *response = malloc(*response_size); if (!*response) return QC_SSH_MEMORY;
    status = agent_io(t, fd, *response, *response_size, 0);
    if (status) { free(*response); *response = NULL; }
    return status;
}
typedef struct {
    qc_ssh_task *task;
    int fd, status;
    const unsigned char *key;
    size_t key_size;
} agent_sign_context;
static int agent_sign_request(LIBSSH2_SESSION *session, unsigned char **sig, size_t *sig_len,
                              const unsigned char *data, size_t data_len, void **abstract) {
    (void)session;
    agent_sign_context *context = *abstract;
    const unsigned char *p = data, *part = NULL; size_t left = data_len, n = 0;
    if (!agent_field(&p, &left, &part, &n) || !left || *p++ != 50) return LIBSSH2_ERROR_AGENT_PROTOCOL;
    left--;
    for (int i = 0; i < 3; ++i) if (!agent_field(&p, &left, &part, &n)) return LIBSSH2_ERROR_AGENT_PROTOCOL;
    if (!left || *p++ != 1) return LIBSSH2_ERROR_AGENT_PROTOCOL;
    left--;
    if (!agent_field(&p, &left, &part, &n) || !n || n > 128 || data_len > AGENT_LIMIT - context->key_size - 13) return LIBSSH2_ERROR_AGENT_PROTOCOL;
    char method[129]; memcpy(method, part, n); method[n] = 0;
    const char *suffix = "-cert-v01@openssh.com";
    if (n >= strlen(suffix) && !strcmp(method + n - strlen(suffix), suffix)) method[n - strlen(suffix)] = 0;
    uint32_t flags = !strcmp(method, "rsa-sha2-512") ? 4 : !strcmp(method, "rsa-sha2-256") ? 2 : 0;
    size_t size = 13 + context->key_size + data_len;
    unsigned char *request = malloc(size), *response = NULL; size_t response_size = 0;
    if (!request) return LIBSSH2_ERROR_ALLOC;
    request[0] = 13; agent_put_u32(request + 1, (uint32_t)context->key_size);
    memcpy(request + 5, context->key, context->key_size);
    agent_put_u32(request + 5 + context->key_size, (uint32_t)data_len);
    memcpy(request + 9 + context->key_size, data, data_len); agent_put_u32(request + size - 4, flags);
    context->status = agent_exchange(context->task, context->fd, request, size, &response, &response_size);
    qc_ssh_wipe(request, size); free(request);
    if (context->status) return LIBSSH2_ERROR_AGENT_PROTOCOL;
    int result = LIBSSH2_ERROR_AGENT_PROTOCOL;
    p = response; left = response_size;
    if (!left || *p++ != 14) goto done;
    left--;
    if (!agent_field(&p, &left, &part, &n) || left) goto done;
    p = part; left = n;
    if (!agent_field(&p, &left, &part, &n) || n != strlen(method) || memcmp(part, method, n)) goto done;
    if (!agent_field(&p, &left, &part, &n) || left || !n || n > 65536) goto done;
    *sig = malloc(n); if (!*sig) { result = LIBSSH2_ERROR_ALLOC; goto done; }
    memcpy(*sig, part, n); *sig_len = n; result = 0;
done:
    qc_ssh_wipe(response, response_size); free(response); return result;
}
static int authenticate_agent(qc_ssh_task *t, int network_fd, LIBSSH2_SESSION *session,
                              const char *username, const char *path) {
    int fd = -1, status = agent_connect_socket(t, path, &fd); if (status) return status;
    unsigned char request = 11, *response = NULL; size_t size = 0;
    status = agent_exchange(t, fd, &request, 1, &response, &size);
    if (status) { close(fd); return status; }
    const unsigned char *p = response; size_t left = size;
    if (left < 5 || *p++ != 12) { status = QC_SSH_AGENT; goto done; }
    uint32_t count = agent_u32(p); p += 4; left -= 5;
    if (!count || count > 64) { status = QC_SSH_AGENT; goto done; }
    status = QC_SSH_AUTH;
    for (uint32_t i = 0; i < count; ++i) {
        const unsigned char *key, *comment; size_t key_size, comment_size;
        if (!agent_field(&p, &left, &key, &key_size) || !key_size || key_size > 65536
            || !agent_field(&p, &left, &comment, &comment_size)) { status = QC_SSH_AGENT; break; }
        (void)comment; (void)comment_size;
        if ((status = check(t))) break;
        agent_sign_context context = {t, fd, 0, key, key_size}; void *abstract = &context;
        int rc;
        do {
            rc = libssh2_userauth_publickey(session, username, key, key_size, agent_sign_request, &abstract);
            if (context.status) { status = context.status; goto done; }
            if (rc == LIBSSH2_ERROR_EAGAIN) { status = wait_socket(t, network_fd, session); if (status) goto done; }
        } while (rc == LIBSSH2_ERROR_EAGAIN);
        if (!rc) { status = QC_SSH_OK; break; }
        status = QC_SSH_AUTH;
    }
done:
    free(response); close(fd); return status;
}
#undef AGENT_LIMIT
