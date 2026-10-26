/* Included by ssh_plugin.c: same authenticated, pinned, cancellable session. */
static int file_error(LIBSSH2_SFTP *sftp) {
    switch (libssh2_sftp_last_error(sftp)) {
    case LIBSSH2_FX_NO_SUCH_FILE: case LIBSSH2_FX_NO_SUCH_PATH: return QC_SSH_NOT_FOUND;
    case LIBSSH2_FX_PERMISSION_DENIED: return QC_SSH_PERMISSION;
    case LIBSSH2_FX_FILE_ALREADY_EXISTS: return QC_SSH_EXISTS;
    case LIBSSH2_FX_OP_UNSUPPORTED: return QC_SSH_UNSUPPORTED;
    default: return QC_SSH_IO;
    }
}
static int file_attributes(qc_ssh_task *t, LIBSSH2_SFTP_ATTRIBUTES *a) {
    char value[192];
    int length = snprintf(value, sizeof(value), "%lu\t%llu\t%lu\t%lu\n", a->flags,
        (unsigned long long)a->filesize, a->permissions, a->mtime);
    unsigned char *data = malloc((size_t)length); if (!data) return QC_SSH_MEMORY;
    memcpy(data, value, (size_t)length); t->result.stderr_data = data; t->result.stderr_length = (size_t)length;
    return 0;
}
static int regular_remote(LIBSSH2_SFTP_ATTRIBUTES *a) {
    return (a->flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) && LIBSSH2_SFTP_S_ISREG(a->permissions);
}
#define FILE_WAIT(expression) do { \
    while ((rc = (expression)) == LIBSSH2_ERROR_EAGAIN) { \
        status = wait_socket(t, fd, session); if (status) goto finish; \
    } \
} while (0)
static int run_file(qc_ssh_task *t, int fd, LIBSSH2_SESSION *session) {
    int status = 0, rc = 0, local = -1, stage_exists = 0;
    LIBSSH2_SFTP *sftp = NULL; LIBSSH2_SFTP_HANDLE *handle = NULL;
    LIBSSH2_SFTP_ATTRIBUTES before = {0}, after = {0};
    char *local_stage = NULL;
    EVP_MD_CTX *hash = NULL;
    const qc_ssh_file_request *r = &t->file;
    for (;;) {
        if ((status = check(t))) goto finish;
        sftp = libssh2_sftp_init(session); if (sftp) break;
        if (libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN) { status = QC_SSH_UNSUPPORTED; goto finish; }
        status = wait_socket(t, fd, session); if (status) goto finish;
    }
    if (r->operation >= QC_SSH_FILE_MKDIR) {
        if (!strcmp(r->remote_path, "/")) { status = QC_SSH_INVALID; goto finish; }
        if (r->operation == QC_SSH_FILE_MKDIR) {
            t->result.command_may_have_run = 1;
            FILE_WAIT(libssh2_sftp_mkdir(sftp, r->remote_path, 0700));
        } else {
            FILE_WAIT(libssh2_sftp_lstat(sftp, r->remote_path, &before));
            if (rc) { status = file_error(sftp); goto finish; }
            if (!(before.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS)) { status = QC_SSH_UNSUPPORTED; goto finish; }
            if (r->operation == QC_SSH_FILE_MOVE) {
                FILE_WAIT(libssh2_sftp_lstat(sftp, r->temporary_path, &after));
                if (!rc) { status = QC_SSH_EXISTS; goto finish; }
                if (libssh2_sftp_last_error(sftp) != LIBSSH2_FX_NO_SUCH_FILE) { status = file_error(sftp); goto finish; }
                t->result.command_may_have_run = 1;
                FILE_WAIT(libssh2_sftp_rename_ex(sftp, r->remote_path, (unsigned int)strlen(r->remote_path),
                    r->temporary_path, (unsigned int)strlen(r->temporary_path), 0));
            } else if (r->operation == QC_SSH_FILE_UNLINK && !LIBSSH2_SFTP_S_ISDIR(before.permissions)) {
                t->result.command_may_have_run = 1;
                FILE_WAIT(libssh2_sftp_unlink(sftp, r->remote_path));
            } else if (r->operation == QC_SSH_FILE_RMDIR && LIBSSH2_SFTP_S_ISDIR(before.permissions)) {
                t->result.command_may_have_run = 1;
                FILE_WAIT(libssh2_sftp_rmdir(sftp, r->remote_path));
            } else { status = QC_SSH_INVALID; goto finish; }
        }
        if (rc) status = file_error(sftp);
        goto finish;
    }
    if (r->operation == QC_SSH_FILE_STAT) {
        FILE_WAIT(libssh2_sftp_lstat(sftp, r->remote_path, &before));
        if (rc) { status = file_error(sftp); goto finish; }
        status = file_attributes(t, &before); goto finish;
    }
    if (r->operation == QC_SSH_FILE_LIST) {
        for (;;) {
            handle = libssh2_sftp_opendir(sftp, r->remote_path); if (handle) break;
            if (libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN) { status = file_error(sftp); goto finish; }
            status = wait_socket(t, fd, session); if (status) goto finish;
        }
        uint64_t seen = 0; uint32_t count = 0;
        for (;;) {
            if ((status = check(t))) goto finish;
            char name[4097], encoded[5468], line[5800]; LIBSSH2_SFTP_ATTRIBUTES a = {0};
            FILE_WAIT(libssh2_sftp_readdir_ex(handle, name, sizeof(name) - 1, NULL, 0, &a));
            if (rc == 0) break;
            if (rc < 0) { status = file_error(sftp); goto finish; }
            if (rc >= 4096) { status = QC_SSH_LIMIT; goto finish; }
            if ((rc == 1 && name[0] == '.') || (rc == 2 && name[0] == '.' && name[1] == '.')) continue;
            if (seen++ < r->offset) continue;
            if (count >= r->maximum_entries) { t->result.truncated = 1; break; }
            EVP_EncodeBlock((unsigned char *)encoded, (const unsigned char *)name, rc);
            int length = snprintf(line, sizeof(line), "%s\t%lu\t%llu\t%lu\t%lu\n", encoded, a.flags,
                (unsigned long long)a.filesize, a.permissions, a.mtime);
            if (t->result.stdout_length + (size_t)length > t->request.maximum_output_bytes) { t->result.truncated = 1; break; }
            status = collect(t, 0, line, (size_t)length); if (status) goto finish;
            count++;
        }
        goto finish;
    }
    if (r->operation == QC_SSH_FILE_UPLOAD) {
        local = open(r->local_path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
        struct stat a;
        if (local < 0 || fstat(local, &a) || !S_ISREG(a.st_mode)) { status = QC_SSH_LOCAL_IO; goto finish; }
        if (a.st_size < 0 || (uint64_t)a.st_size > r->maximum_transfer_bytes) { status = QC_SSH_LIMIT; goto finish; }
        transfer_progress(t, 1, 0, (uint64_t)a.st_size, 1);
        FILE_WAIT(libssh2_sftp_lstat(sftp, r->remote_path, &before));
        if (rc == 0 && !r->overwrite) { status = QC_SSH_EXISTS; goto finish; }
        if (rc == 0 && !regular_remote(&before)) { status = QC_SSH_INVALID; goto finish; }
        if (rc && libssh2_sftp_last_error(sftp) != LIBSSH2_FX_NO_SUCH_FILE) { status = file_error(sftp); goto finish; }
        for (;;) {
            handle = libssh2_sftp_open(sftp, r->temporary_path, LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL, 0600);
            if (handle) { stage_exists = 1; break; }
            if (libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN) { status = file_error(sftp); goto finish; }
            status = wait_socket(t, fd, session); if (status) goto finish;
        }
        hash = EVP_MD_CTX_new();
        if (!hash || !EVP_DigestInit_ex(hash, EVP_sha256(), NULL)) { status = QC_SSH_MEMORY; goto finish; }
        uint64_t total = 0;
        for (;;) {
            if ((status = check(t))) goto finish;
            char buffer[65536]; ssize_t n = read(local, buffer, sizeof(buffer));
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) { status = QC_SSH_LOCAL_IO; goto finish; }
            if (!n) break;
            if (total + (uint64_t)n > r->maximum_transfer_bytes) { status = QC_SSH_LIMIT; goto finish; }
            if (!EVP_DigestUpdate(hash, buffer, (size_t)n)) { status = QC_SSH_IO; goto finish; }
            size_t at = 0;
            while (at < (size_t)n) {
                if ((status = check(t))) goto finish;
                ssize_t written = libssh2_sftp_write(handle, buffer + at, (size_t)n - at);
                if (written == LIBSSH2_ERROR_EAGAIN) { status = wait_socket(t, fd, session); if (status) goto finish; continue; }
                if (written <= 0) { status = file_error(sftp); goto finish; }
                at += (size_t)written;
                transfer_progress(t, 1, total + at, (uint64_t)a.st_size, 1);
            }
            total += (uint64_t)n;
        }
        transfer_progress(t, 2, total, (uint64_t)a.st_size, 1);
        struct stat b;
        if (fstat(local, &b) || a.st_size != b.st_size || a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec
            || a.st_mtimespec.tv_nsec != b.st_mtimespec.tv_nsec || (uint64_t)a.st_size != total) { status = QC_SSH_CHANGED; goto finish; }
        FILE_WAIT(libssh2_sftp_close(handle)); handle = NULL;
        if (rc) { status = file_error(sftp); goto finish; }
        if ((status = check(t))) goto finish;
        transfer_progress(t, 3, total, (uint64_t)a.st_size, 1);
        t->result.command_may_have_run = 1;
        if (r->overwrite) { FILE_WAIT(libssh2_sftp_posix_rename(sftp, r->temporary_path, r->remote_path)); }
        else { FILE_WAIT(libssh2_sftp_rename_ex(sftp, r->temporary_path, (unsigned int)strlen(r->temporary_path), r->remote_path, (unsigned int)strlen(r->remote_path), 0)); }
        if (rc) { status = file_error(sftp); goto finish; }
        stage_exists = 0; t->result.output_bytes = total;
    } else {
        for (;;) {
            handle = libssh2_sftp_open(sftp, r->remote_path, LIBSSH2_FXF_READ, 0); if (handle) break;
            if (libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN) { status = file_error(sftp); goto finish; }
            status = wait_socket(t, fd, session); if (status) goto finish;
        }
        FILE_WAIT(libssh2_sftp_fstat(handle, &before));
        if (rc) { status = file_error(sftp); goto finish; }
        if (!regular_remote(&before)) { status = QC_SSH_INVALID; goto finish; }
        if (r->operation == QC_SSH_FILE_READ) {
            libssh2_sftp_seek64(handle, r->offset);
            size_t used = 0, limit = t->request.maximum_output_bytes;
            while (used <= limit) {
                if ((status = check(t))) goto finish;
                char buffer[16384]; size_t wanted = limit + 1 - used;
                if (wanted > sizeof(buffer)) wanted = sizeof(buffer);
                ssize_t n = libssh2_sftp_read(handle, buffer, wanted);
                if (n == LIBSSH2_ERROR_EAGAIN) { status = wait_socket(t, fd, session); if (status) goto finish; continue; }
                if (n < 0) { status = file_error(sftp); goto finish; }
                if (!n) break;
                status = collect(t, 0, buffer, (size_t)n); if (status) goto finish;
                used += (size_t)n;
            }
            status = file_attributes(t, &before); goto finish;
        }
        if ((before.flags & LIBSSH2_SFTP_ATTR_SIZE) && before.filesize > r->maximum_transfer_bytes) { status = QC_SSH_LIMIT; goto finish; }
        transfer_progress(t, 1, 0, before.filesize, before.flags & LIBSSH2_SFTP_ATTR_SIZE);
        struct stat destination;
        if (lstat(r->local_path, &destination) == 0) {
            if (!r->overwrite) { status = QC_SSH_EXISTS; goto finish; }
            if (!S_ISREG(destination.st_mode)) { status = QC_SSH_LOCAL_IO; goto finish; }
        } else if (errno != ENOENT) { status = QC_SSH_LOCAL_IO; goto finish; }
        local_stage = malloc(strlen(r->local_path) + 40);
        if (!local_stage) { status = QC_SSH_MEMORY; goto finish; }
        if (r->temporary_path) {
            free(local_stage); local_stage = strdup(r->temporary_path);
            if (!local_stage) { status = QC_SSH_MEMORY; goto finish; }
            local = open(local_stage, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
            if (local < 0) { free(local_stage); local_stage = NULL; status = QC_SSH_LOCAL_IO; goto finish; }
        } else {
            sprintf(local_stage, "%s.querycraft-XXXXXX", r->local_path);
            local = mkstemp(local_stage); if (local < 0) { free(local_stage); local_stage = NULL; status = QC_SSH_LOCAL_IO; goto finish; }
        }
        fchmod(local, 0600);
        hash = EVP_MD_CTX_new();
        if (!hash || !EVP_DigestInit_ex(hash, EVP_sha256(), NULL)) { status = QC_SSH_MEMORY; goto finish; }
        uint64_t total = 0;
        for (;;) {
            if ((status = check(t))) goto finish;
            char buffer[65536]; ssize_t n = libssh2_sftp_read(handle, buffer, sizeof(buffer));
            if (n == LIBSSH2_ERROR_EAGAIN) { status = wait_socket(t, fd, session); if (status) goto finish; continue; }
            if (n < 0) { status = file_error(sftp); goto finish; }
            if (!n) break;
            if (total + (uint64_t)n > r->maximum_transfer_bytes) { status = QC_SSH_LIMIT; goto finish; }
            if (!EVP_DigestUpdate(hash, buffer, (size_t)n)) { status = QC_SSH_IO; goto finish; }
            size_t at = 0;
            while (at < (size_t)n) {
                ssize_t written = write(local, buffer + at, (size_t)n - at);
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) { status = QC_SSH_LOCAL_IO; goto finish; }
                at += (size_t)written;
                transfer_progress(t, 1, total + at, before.filesize, before.flags & LIBSSH2_SFTP_ATTR_SIZE);
            }
            total += (uint64_t)n;
        }
        transfer_progress(t, 2, total, before.filesize, before.flags & LIBSSH2_SFTP_ATTR_SIZE);
        FILE_WAIT(libssh2_sftp_fstat(handle, &after));
        if (rc || ((before.flags & LIBSSH2_SFTP_ATTR_SIZE) && total != before.filesize)
            || ((before.flags & after.flags & LIBSSH2_SFTP_ATTR_SIZE) && before.filesize != after.filesize)
            || ((before.flags & after.flags & LIBSSH2_SFTP_ATTR_ACMODTIME) && before.mtime != after.mtime)) { status = QC_SSH_CHANGED; goto finish; }
        if (fsync(local)) { status = QC_SSH_LOCAL_IO; goto finish; }
        if ((status = check(t))) goto finish;
        transfer_progress(t, 3, total, before.filesize, before.flags & LIBSSH2_SFTP_ATTR_SIZE);
        t->result.command_may_have_run = 1;
        rc = r->overwrite ? rename(local_stage, r->local_path) : link(local_stage, r->local_path);
        if (rc) { status = errno == EEXIST ? QC_SSH_EXISTS : QC_SSH_LOCAL_IO; goto finish; }
        if (!r->overwrite) unlink(local_stage);
        free(local_stage); local_stage = NULL; t->result.output_bytes = total;
    }
    {
        unsigned char digest[EVP_MAX_MD_SIZE]; unsigned int size = 0;
        if (!EVP_DigestFinal_ex(hash, digest, &size) || size != 32) { status = QC_SSH_IO; goto finish; }
        char hex[65]; for (unsigned int i = 0; i < size; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
        /* Hash text is fixed ASCII; no binary file bytes enter MCP responses. */
        status = collect(t, 0, hex, 64);
        t->result.output_bytes -= 64;
    }
finish:
    if (hash) EVP_MD_CTX_free(hash);
    if (local >= 0) close(local);
    if (local_stage) { unlink(local_stage); free(local_stage); }
    if (sftp) {
        libssh2_session_set_blocking(session, 1); libssh2_session_set_timeout(session, 100);
        if (handle && libssh2_sftp_close(handle)) t->session_reusable = 0;
        if (stage_exists) libssh2_sftp_unlink(sftp, r->temporary_path);
        if (libssh2_sftp_shutdown(sftp)) t->session_reusable = 0;
        libssh2_session_set_blocking(session, 0);
    }
    if (!status) t->result.exit_status = 0;
    return status;
}
#undef FILE_WAIT
