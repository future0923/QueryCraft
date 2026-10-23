/* Optional pool extension. Every busy slot has exactly one libssh2 worker.
   Controls touch metadata under mutex, never a busy session or its socket. */
#define POOL_LIMIT 8
typedef struct {
    LIBSSH2_SESSION *session;
    int fd, busy, invalidated;
    unsigned char binding[32];
    char scope[129];
    double created, idle_since;
} pool_slot;
struct qc_ssh_pool {
    pthread_mutex_t mutex;
    uint32_t maximum;
    double idle_seconds, lifetime_seconds;
    unsigned char salt[32];
    pool_slot slots[POOL_LIMIT];
};
static void close_session(int fd, LIBSSH2_SESSION *session) {
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
    if (session) {
        libssh2_session_set_blocking(session, 1); libssh2_session_set_timeout(session, 100);
        libssh2_session_free(session);
    }
    if (fd >= 0) close(fd);
}
static void clear_slot(pool_slot *slot) {
    close_session(slot->fd, slot->session);
    qc_ssh_wipe(slot, sizeof(*slot)); slot->fd = -1;
}
static int socket_live(int fd) {
    unsigned char byte;
    ssize_t n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
    return n > 0 || (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR));
}
static int expired(qc_ssh_pool *pool, pool_slot *slot, double now) {
    return slot->invalidated || now - slot->created >= pool->lifetime_seconds
        || now - slot->idle_since >= pool->idle_seconds;
}
static int hash_field(EVP_MD_CTX *hash, const void *value, size_t size) {
    uint64_t length = size;
    return EVP_DigestUpdate(hash, &length, sizeof(length)) && (!size || EVP_DigestUpdate(hash, value, size));
}
static int pool_binding(qc_ssh_pool *pool, qc_ssh_task *t, const char *scope,
                        char **key, size_t *key_length, unsigned char binding[32]) {
    if (t->request.private_key_path) {
        int status = read_private_key(t, key, key_length); if (status) return status;
    }
    EVP_MD_CTX *hash = EVP_MD_CTX_new(); if (!hash) return QC_SSH_MEMORY;
    int ok = EVP_DigestInit_ex(hash, EVP_sha256(), NULL) && hash_field(hash, pool->salt, sizeof(pool->salt));
    const char *fields[] = {scope, t->request.host, t->request.username, t->request.host_fingerprint,
        t->request.private_key_path, t->request.secret};
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i)
        ok = ok && hash_field(hash, fields[i], fields[i] ? strlen(fields[i]) : 0);
    ok = ok && hash_field(hash, &t->request.port, sizeof(t->request.port)) && hash_field(hash, *key, *key_length);
    unsigned int size = 0; ok = ok && EVP_DigestFinal_ex(hash, binding, &size) && size == 32;
    EVP_MD_CTX_free(hash); return ok ? QC_SSH_OK : QC_SSH_MEMORY;
}
static int checkout(qc_ssh_pool *pool, const char *scope, const unsigned char binding[32],
                    int *index, int *fd, LIBSSH2_SESSION **session) {
    pthread_mutex_lock(&pool->mutex);
    double now = monotonic_time(); int empty = -1, oldest = -1, found = -1;
    for (uint32_t i = 0; i < pool->maximum; ++i) {
        pool_slot *slot = &pool->slots[i];
        int changed = !strcmp(slot->scope, scope) && memcmp(slot->binding, binding, 32);
        if (slot->busy) { if (changed) slot->invalidated = 1; continue; }
        if (slot->session && (changed || expired(pool, slot, now) || !socket_live(slot->fd))) clear_slot(slot);
        if (!slot->session) { if (empty < 0) empty = (int)i; continue; }
        if (!strcmp(slot->scope, scope) && !memcmp(slot->binding, binding, 32)) { found = (int)i; break; }
        if (oldest < 0 || slot->idle_since < pool->slots[oldest].idle_since) oldest = (int)i;
    }
    if (found < 0) found = empty >= 0 ? empty : oldest;
    if (found < 0) { pthread_mutex_unlock(&pool->mutex); return QC_SSH_CAPACITY; }
    pool_slot *slot = &pool->slots[found];
    if (strcmp(slot->scope, scope) || memcmp(slot->binding, binding, 32)) clear_slot(slot);
    if (!slot->session) { slot->created = now; memcpy(slot->binding, binding, 32); strcpy(slot->scope, scope); }
    slot->busy = 1; slot->invalidated = 0;
    *index = found; *fd = slot->fd; *session = slot->session;
    pthread_mutex_unlock(&pool->mutex); return 0;
}
static void checkin(qc_ssh_pool *pool, int index, int fd, LIBSSH2_SESSION *session, int reusable) {
    pthread_mutex_lock(&pool->mutex);
    pool_slot *slot = &pool->slots[index];
    slot->fd = fd; slot->session = session; slot->busy = 0; slot->idle_since = monotonic_time();
    if (!reusable || expired(pool, slot, slot->idle_since)) clear_slot(slot);
    pthread_mutex_unlock(&pool->mutex);
}
EXPORT uint32_t querycraft_ssh_plugin_pool_version(void) { return 1; }
EXPORT qc_ssh_pool *querycraft_ssh_plugin_pool_create(uint32_t maximum, uint32_t idle_ms, uint32_t lifetime_ms) {
    if (!maximum || maximum > POOL_LIMIT || !idle_ms || idle_ms > 60000 || !lifetime_ms || lifetime_ms > 300000) return NULL;
    qc_ssh_pool *pool = calloc(1, sizeof(*pool)); if (!pool) return NULL;
    if (RAND_bytes(pool->salt, sizeof(pool->salt)) != 1) { free(pool); return NULL; }
    pthread_mutex_init(&pool->mutex, NULL); pool->maximum = maximum;
    pool->idle_seconds = idle_ms / 1000.0; pool->lifetime_seconds = lifetime_ms / 1000.0;
    for (int i = 0; i < POOL_LIMIT; ++i) pool->slots[i].fd = -1;
    return pool;
}
EXPORT void querycraft_ssh_plugin_pool_invalidate(qc_ssh_pool *pool, const char *scope) {
    if (!pool) return;
    pthread_mutex_lock(&pool->mutex);
    for (uint32_t i = 0; i < pool->maximum; ++i) {
        pool_slot *slot = &pool->slots[i];
        if (scope && strcmp(scope, slot->scope)) continue;
        if (slot->busy) slot->invalidated = 1; else clear_slot(slot);
    }
    pthread_mutex_unlock(&pool->mutex);
}
EXPORT void querycraft_ssh_plugin_pool_prune(qc_ssh_pool *pool) {
    if (!pool) return;
    pthread_mutex_lock(&pool->mutex); double now = monotonic_time();
    for (uint32_t i = 0; i < pool->maximum; ++i) {
        pool_slot *slot = &pool->slots[i];
        if (!slot->busy && slot->session && (expired(pool, slot, now) || !socket_live(slot->fd))) clear_slot(slot);
    }
    pthread_mutex_unlock(&pool->mutex);
}
EXPORT void querycraft_ssh_plugin_pool_destroy(qc_ssh_pool *pool) {
    if (!pool) return;
    /* Caller keeps the pool alive through every run/control call. */
    querycraft_ssh_plugin_pool_invalidate(pool, NULL);
    pthread_mutex_destroy(&pool->mutex); qc_ssh_wipe(pool, sizeof(*pool)); free(pool);
}
