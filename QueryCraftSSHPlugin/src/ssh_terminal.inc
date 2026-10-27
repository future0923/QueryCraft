/* Optional persistent PTY transport. Only the run worker calls libssh2. */
EXPORT uint32_t querycraft_ssh_plugin_terminal_version(void) { return 1; }
EXPORT int32_t querycraft_ssh_plugin_set_terminal(qc_ssh_task *t, int32_t fd, uint32_t cols, uint32_t rows) {
    if (!t || t->terminal_fd >= 0 || t->request.command || t->file.operation || t->scan_host_key
        || fd < 0 || cols < 2 || cols > 1000 || rows < 2 || rows > 1000) return QC_SSH_INVALID;
    int type = 0; socklen_t length = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) || type != SOCK_STREAM) return QC_SSH_INVALID;
    int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0); if (copy < 0) return QC_SSH_IO;
    int flags = fcntl(copy, F_GETFL, 0), yes = 1;
    if (flags < 0 || fcntl(copy, F_SETFL, flags | O_NONBLOCK) || setsockopt(copy, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes))) {
        close(copy); return QC_SSH_IO;
    }
    t->terminal_fd = copy; atomic_store(&t->terminal_dimensions, (cols << 16) | rows); return QC_SSH_OK;
}
EXPORT void querycraft_ssh_plugin_terminal_resize(qc_ssh_task *t, uint32_t cols, uint32_t rows) {
    if (t && cols >= 2 && cols <= 1000 && rows >= 2 && rows <= 1000)
        atomic_store(&t->terminal_dimensions, (cols << 16) | rows);
}
EXPORT uint32_t querycraft_ssh_plugin_terminal_ready(qc_ssh_task *t) { return t ? atomic_load(&t->terminal_ready) : 0; }
static int terminal_output(qc_ssh_task *t, const char *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        int status = check(t); if (status) return status;
        ssize_t n = send(t->terminal_fd, bytes + offset, length - offset, 0);
        if (n > 0) { offset += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd p = {t->terminal_fd, POLLOUT, 0};
            if (poll(&p, 1, 50) < 0 && errno != EINTR) return QC_SSH_IO;
            if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) return QC_SSH_CANCELLED;
            continue;
        }
        return QC_SSH_CANCELLED;
    }
    return QC_SSH_OK;
}
static int run_terminal(qc_ssh_task *t, int fd, LIBSSH2_SESSION *session) {
    LIBSSH2_CHANNEL *channel = NULL;
    int status = 0, rc;
    unsigned dimensions = atomic_load(&t->terminal_dimensions);
    do {
        if ((status = check(t))) goto done;
        channel = libssh2_channel_open_session(session);
        if (channel) break;
        if (libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN) { status = QC_SSH_IO; goto done; }
        if ((status = wait_socket(t, fd, session))) goto done;
    } while (1);
    while ((rc = libssh2_channel_request_pty_ex(channel, "xterm-256color", 14, NULL, 0, dimensions >> 16, dimensions & 65535, 0, 0)) == LIBSSH2_ERROR_EAGAIN)
        if ((status = wait_socket(t, fd, session))) goto done;
    if (rc) { status = QC_SSH_UNSUPPORTED; goto done; }
    t->result.command_may_have_run = 1;
    while ((rc = libssh2_channel_shell(channel)) == LIBSSH2_ERROR_EAGAIN)
        if ((status = wait_socket(t, fd, session))) goto done;
    if (rc) { status = QC_SSH_UNSUPPORTED; goto done; }
    t->deadline = 1e100; /* Setup deadline does not terminate a live interactive shell. */
    atomic_store(&t->terminal_ready, 1);
    libssh2_keepalive_config(session, 1, 15);
    for (;;) {
        if ((status = check(t))) goto done;
        unsigned next = atomic_load(&t->terminal_dimensions);
        if (next != dimensions) {
            while ((rc = libssh2_channel_request_pty_size(channel, next >> 16, next & 65535)) == LIBSSH2_ERROR_EAGAIN)
                if ((status = wait_socket(t, fd, session))) goto done;
            if (rc) { status = QC_SSH_IO; goto done; }
            dimensions = next;
        }
        char input[16384];
        ssize_t count = recv(t->terminal_fd, input, sizeof(input), 0);
        if (count == 0) { status = QC_SSH_CANCELLED; goto done; }
        if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) { status = QC_SSH_IO; goto done; }
        size_t offset = 0;
        while (count > 0 && offset < (size_t)count) {
            ssize_t written = libssh2_channel_write(channel, input + offset, (size_t)count - offset);
            if (written > 0) offset += (size_t)written;
            else if (written == LIBSSH2_ERROR_EAGAIN || written == 0) {
                if ((status = wait_socket(t, fd, session))) goto done;
            } else { status = QC_SSH_IO; goto done; }
            if ((status = check(t))) goto done;
        }
        qc_ssh_wipe(input, sizeof(input));
        int progress = count > 0;
        for (int stream = 0; stream < 2; ++stream) {
            char output[16384];
            ssize_t n = libssh2_channel_read_ex(channel, stream, output, sizeof(output));
            if (n > 0) { progress = 1; if ((status = terminal_output(t, output, (size_t)n))) goto done; }
            else if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) { status = QC_SSH_IO; goto done; }
        }
        if (!progress && libssh2_channel_eof(channel)) {
            t->result.exit_status = libssh2_channel_get_exit_status(channel); break;
        }
        int seconds = 0;
        rc = libssh2_keepalive_send(session, &seconds);
        if (rc && rc != LIBSSH2_ERROR_EAGAIN) { status = QC_SSH_IO; goto done; }
        if (!progress) {
            /* POLLOUT is normally always ready: poll inbound only while idle. */
            struct pollfd p[2] = {{fd, POLLIN, 0}, {t->terminal_fd, POLLIN, 0}};
            if (poll(p, 2, 15) < 0 && errno != EINTR) { status = QC_SSH_IO; goto done; }
            if (p[1].revents & (POLLHUP | POLLERR | POLLNVAL)) { status = QC_SSH_CANCELLED; goto done; }
        }
    }
done:
    atomic_store(&t->terminal_ready, 0);
    /* Session teardown owns the channel; never block close waiting for remote EOF. */
    shutdown(t->terminal_fd, SHUT_RDWR);
    return status;
}
