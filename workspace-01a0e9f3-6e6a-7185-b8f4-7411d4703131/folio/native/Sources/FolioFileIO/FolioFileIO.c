#define _GNU_SOURCE 1
#include "FolioFileIO.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#include <copyfile.h>
#include <sys/xattr.h>
#else
#include <openssl/sha.h>
#include <sys/xattr.h>
#endif

static int system_error(void) { int value = errno; return value ? value : EIO; }

static int valid_component(const char *s) {
    return *s && strcmp(s, ".") && strcmp(s, "..") && !strchr(s, '\\');
}
static int64_t bounded_ns(int64_t seconds, int64_t nanos) {
    int64_t result;
    if (__builtin_mul_overflow(seconds, 1000000000LL, &result)) return seconds < 0 ? INT64_MIN : INT64_MAX;
    int64_t total;
    if (__builtin_add_overflow(result, nanos, &total)) return result < 0 ? INT64_MIN : INT64_MAX;
    return total;
}
static void file_info(const struct stat *s, FolioFileInfo *i) {
    memset(i, 0, sizeof(*i));
    i->device = s->st_dev; i->inode = s->st_ino; i->size = s->st_size;
    i->permissions = s->st_mode & 0777;
    i->kind = S_ISREG(s->st_mode) ? 1 : S_ISDIR(s->st_mode) ? 2 : 3;
#if defined(__APPLE__)
    i->modified_ns = bounded_ns(s->st_mtimespec.tv_sec, s->st_mtimespec.tv_nsec);
    i->changed_ns = bounded_ns(s->st_ctimespec.tv_sec, s->st_ctimespec.tv_nsec);
#else
    i->modified_ns = bounded_ns(s->st_mtim.tv_sec, s->st_mtim.tv_nsec);
    i->changed_ns = bounded_ns(s->st_ctim.tv_sec, s->st_ctim.tv_nsec);
#endif
}
/* This function never concatenates a trusted root string with an untrusted
   path and then follows it. Each ancestor is opened without symlink following. */
static int parent_of(int root, const char *path, int create, int *parent, char **leaf) {
    if (!path || !*path || *path == '/' || strlen(path) > 4096 || path[strlen(path)-1] == '/') return EINVAL;
    char *copy = strdup(path); if (!copy) return ENOMEM;
    int fd = dup(root); if (fd < 0) { free(copy); return system_error(); }
    char *component = copy;
    int error = 0;
    for (;;) {
        char *separator = strchr(component, '/');
        if (separator) *separator = 0;
        if (!valid_component(component)) { error = EINVAL; break; }
        if (!separator) {
            *leaf = strdup(component);
            if (!*leaf) { error = ENOMEM; break; }
            *parent = fd; free(copy); return 0;
        }
        if (create && mkdirat(fd, component, 0700) < 0 && errno != EEXIST) { error = system_error(); break; }
        int next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (next < 0) { error = system_error(); break; }
        if (create && fsync(fd) < 0) { error = system_error(); close(next); break; }
        close(fd); fd = next; component = separator + 1;
    }
    close(fd); free(copy); return error;
}
static int full_sync(int fd) {
    if (fsync(fd) < 0) return system_error();
#if defined(__APPLE__)
    /* Fail closed if the selected volume cannot honour the stronger barrier.
       This branch requires actual APFS/macOS validation before release. */
    if (fcntl(fd, F_FULLFSYNC) < 0) return system_error();
#endif
    return 0;
}
int folio_open_root(const char *path) { return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW); }
void folio_close_fd(int fd) { if (fd >= 0) close(fd); }
int folio_last_errno(void) { return system_error(); }
int folio_root_info(int root, FolioFileInfo *info) {
    struct stat s; if (fstat(root, &s) < 0) return system_error(); file_info(&s, info); return 0;
}
void folio_free_bytes(void *p) { free(p); }
int folio_make_directory(int root, const char *relative) {
    int parent = -1; char *leaf = NULL; int e = parent_of(root, relative, 1, &parent, &leaf); if (e) return e;
    if (mkdirat(parent, leaf, 0700) < 0 && errno != EEXIST) e = system_error();
    if (!e) {
        int dir = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (dir < 0) e = system_error(); else { if (fsync(dir) < 0) e = system_error(); close(dir); }
    }
    if (!e && fsync(parent) < 0) e = system_error();
    close(parent); free(leaf); return e;
}
int folio_stat_file(int root, const char *relative, FolioFileInfo *info) {
    int parent = -1; char *leaf = NULL; int e = parent_of(root, relative, 0, &parent, &leaf); if (e) return e;
    struct stat s;
    if (fstatat(parent, leaf, &s, AT_SYMLINK_NOFOLLOW) < 0) e = system_error();
    else { file_info(&s, info); if (!S_ISREG(s.st_mode) && !S_ISDIR(s.st_mode)) e = ELOOP; }
    close(parent); free(leaf); return e;
}
int folio_read_file(int root, const char *relative, size_t limit,
                    unsigned char **bytes, size_t *length, FolioFileInfo *info) {
    *bytes = NULL; *length = 0;
    int parent = -1; char *leaf = NULL; int e = parent_of(root, relative, 0, &parent, &leaf); if (e) return e;
    int fd = openat(parent, leaf, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) e = system_error();
    close(parent); free(leaf); if (e) return e;
    struct stat before, after;
    if (fstat(fd, &before) < 0) e = system_error();
    else if (!S_ISREG(before.st_mode)) e = EINVAL;
    else if (before.st_size < 0 || (uint64_t)before.st_size > limit) e = EFBIG;
    unsigned char *buffer = NULL;
    if (!e) { buffer = malloc((size_t)before.st_size + 1); if (!buffer) e = ENOMEM; }
    size_t used = 0;
    while (!e && used < (size_t)before.st_size) {
        ssize_t n = read(fd, buffer + used, (size_t)before.st_size - used);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { e = system_error(); break; }
        if (n == 0) { e = EAGAIN; break; }
        used += (size_t)n;
    }
    if (!e && fstat(fd, &after) < 0) e = system_error();
    if (!e) {
        FolioFileInfo a, b; file_info(&before, &a); file_info(&after, &b);
        if (a.size != b.size || a.modified_ns != b.modified_ns || a.changed_ns != b.changed_ns) e = EAGAIN;
        else { *info = b; *bytes = buffer; *length = used; buffer = NULL; }
    }
    free(buffer); close(fd); return e;
}
int folio_write_new(int root, const char *relative, const unsigned char *bytes,
                    size_t length, uint32_t permissions) {
    int parent = -1; char *leaf = NULL; int e = parent_of(root, relative, 0, &parent, &leaf); if (e) return e;
    int fd = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions & 0777);
    if (fd < 0) e = system_error();
    if (!e && fchmod(fd, permissions & 0777) < 0) e = system_error();
    size_t written = 0;
    while (!e && written < length) {
        ssize_t n = write(fd, bytes + written, length - written);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { e = n < 0 ? system_error() : EIO; break; }
        written += (size_t)n;
    }
    if (!e) e = full_sync(fd);
    if (!e && fsync(parent) < 0) e = system_error();
    /* A failed staging write remains for inspection; never expose it as a note. */
    if (fd >= 0) close(fd);
    close(parent); free(leaf); return e;
}
int folio_list_directory(int root, const char *relative, size_t limit,
                         FolioDirectoryEntry **entries, size_t *count) {
    *entries = NULL; *count = 0;
    int fd = -1, error = 0;
    if (!relative || !*relative) fd = openat(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    else {
        int parent = -1; char *leaf = NULL; error = parent_of(root, relative, 0, &parent, &leaf);
        if (error) return error;
        fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) error = system_error();
        close(parent); free(leaf);
    }
    if (fd < 0) return error ? error : system_error();
    DIR *dir = fdopendir(fd); if (!dir) { error = system_error(); close(fd); return error; }
    FolioDirectoryEntry *result = NULL; size_t n = 0, capacity = 0;
    for (;;) {
        errno = 0; struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) error = system_error(); break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (n >= limit) { error = EFBIG; break; }
        struct stat st;
        if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0) {
            if (errno == ENOENT) continue;
            error = system_error(); break;
        }
        if (n == capacity) {
            size_t next = capacity ? capacity * 2 : 32;
            FolioDirectoryEntry *grown = realloc(result, next * sizeof(*result));
            if (!grown) { error = ENOMEM; break; } result = grown; capacity = next;
        }
        result[n].name = strdup(entry->d_name);
        if (!result[n].name) { error = ENOMEM; break; }
        file_info(&st, &result[n].info); n++;
    }
    closedir(dir);
    if (error) { folio_free_entries(result, n); return error; }
    *entries = result; *count = n; return 0;
}
void folio_free_entries(FolioDirectoryEntry *entries, size_t count) {
    for (size_t i = 0; i < count; i++) free(entries[i].name); free(entries);
}
int folio_link_new(int root, const char *source, const char *destination) {
    int a = -1, b = -1; char *x = NULL, *y = NULL;
    int e = parent_of(root, source, 0, &a, &x); if (e) return e;
    e = parent_of(root, destination, 0, &b, &y);
    if (!e) {
        if (linkat(a, x, b, y, 0) < 0) e = system_error();
        if (!e && fsync(b) < 0) e = system_error();
        close(b); free(y);
    }
    close(a); free(x); return e;
}
int folio_exchange(int root, const char *source, const char *destination) {
    int a = -1, b = -1; char *x = NULL, *y = NULL;
    int e = parent_of(root, source, 0, &a, &x); if (e) return e;
    e = parent_of(root, destination, 0, &b, &y);
    if (!e) {
#if defined(__APPLE__)
        if (renameatx_np(a, x, b, y, RENAME_SWAP) < 0) e = system_error();
#else
        if (renameat2(a, x, b, y, RENAME_EXCHANGE) < 0) e = system_error();
#endif
        if (!e && fsync(a) < 0) e = system_error();
        if (!e && fsync(b) < 0) e = system_error();
        close(b); free(y);
    }
    close(a); free(x); return e;
}

/* Preserve supported Unix ownership/mode, ACLs and xattrs on replacement.
   A failure blocks installation rather than silently dropping metadata.
   Birth time, filesystem flags and provider-specific semantics still need Mac
   validation; cloud/file-provider roots are not a supported development target. */
int folio_copy_metadata(int root, const char *source, const char *destination) {
    int a = -1, b = -1; char *x = NULL, *y = NULL;
    int e = parent_of(root, source, 0, &a, &x); if (e) return e;
    e = parent_of(root, destination, 0, &b, &y);
    if (e) { close(a); free(x); return e; }
    int src = openat(a, x, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    int dst = openat(b, y, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (src < 0 || dst < 0) e = system_error();
    struct stat from = {0}, to = {0};
    if (!e && (fstat(src, &from) < 0 || fstat(dst, &to) < 0)) e = system_error();
    if (!e && (!S_ISREG(from.st_mode) || !S_ISREG(to.st_mode))) e = EINVAL;
    if (!e && (!(from.st_mode & S_IWUSR) || (from.st_mode & (S_ISUID | S_ISGID)))) e = EACCES;
    if (!e && fchown(dst, from.st_uid, from.st_gid) < 0) e = system_error();
    if (!e && fchmod(dst, from.st_mode & 0777) < 0) e = system_error();
    ssize_t size = 0;
    char *names = NULL;
    if (!e) {
#if defined(__APPLE__)
        size = flistxattr(src, NULL, 0, 0);
#else
        size = flistxattr(src, NULL, 0);
#endif
        if (size < 0) e = system_error();
        else if (size > 65536) e = EFBIG;
        else if (size > 0) {
            names = malloc((size_t)size); if (!names) e = ENOMEM;
            else {
#if defined(__APPLE__)
                size = flistxattr(src, names, (size_t)size, 0);
#else
                size = flistxattr(src, names, (size_t)size);
#endif
                if (size < 0) e = system_error();
            }
        }
    }
    if (!e && size > 0 && !names) e = ENOMEM;
#if !defined(__APPLE__)
    /* Remove destination-only inherited attributes, especially ACL entries:
       retaining a staging-directory ACL could broaden an existing note's access. */
    if (!e) {
        ssize_t dst_size = flistxattr(dst, NULL, 0);
        if (dst_size < 0) e = system_error();
        else if (dst_size > 65536) e = EFBIG;
        else if (dst_size > 0) {
            char *dst_names = malloc((size_t)dst_size);
            if (!dst_names) e = ENOMEM;
            else {
                dst_size = flistxattr(dst, dst_names, (size_t)dst_size);
                if (dst_size < 0) e = system_error();
                for (size_t off = 0; !e && off < (size_t)dst_size;) {
                    const char *name = dst_names + off;
                    size_t len = strnlen(name, (size_t)dst_size - off);
                    if (len == (size_t)dst_size - off) { e = EINVAL; break; }
                    off += len + 1;
                    int found = 0;
                    for (size_t n = 0; names && n < (size_t)size;) {
                        size_t length = strnlen(names + n, (size_t)size - n);
                        if (length == (size_t)size - n) { e = EINVAL; break; }
                        if (!strcmp(names + n, name)) found = 1;
                        n += length + 1;
                    }
                    if (!e && !found && fremovexattr(dst, name) < 0) e = system_error();
                }
                free(dst_names);
            }
        }
    }
#endif
    size_t total = 0;
    for (size_t offset = 0; !e && names && offset < (size_t)size;) {
        const char *name = names + offset;
        size_t name_length = strnlen(name, (size_t)size - offset);
        if (name_length == (size_t)size - offset) { e = EINVAL; break; }
        offset += name_length + 1;
#if defined(__APPLE__)
        ssize_t n = fgetxattr(src, name, NULL, 0, 0, 0);
#else
        ssize_t n = fgetxattr(src, name, NULL, 0);
#endif
        if (n < 0) { e = system_error(); break; }
        total += (size_t)n;
        if (total > 1048576) { e = EFBIG; break; }
#if !defined(__APPLE__)
        void *value = malloc((size_t)n + 1);
        if (!value) { e = ENOMEM; break; }
        ssize_t actual = fgetxattr(src, name, value, (size_t)n);
        if (actual < 0) e = system_error();
        else if (fsetxattr(dst, name, value, (size_t)actual, 0) < 0) e = system_error();
        free(value);
#endif
    }
#if defined(__APPLE__)
    if (!e && fcopyfile(src, dst, NULL, COPYFILE_ACL | COPYFILE_XATTR) < 0) e = system_error();
#endif
    free(names);
    if (!e) e = full_sync(dst);
    if (src >= 0) close(src); if (dst >= 0) close(dst);
    close(a); close(b); free(x); free(y); return e;
}

int folio_sync_parent(int root, const char *relative) {
    int parent = -1; char *leaf = NULL; int e = parent_of(root, relative, 0, &parent, &leaf); if (e) return e;
    if (fsync(parent) < 0) e = system_error();
    close(parent); free(leaf); return e;
}
static int remove_item(int root, const char *relative, int flags) {
    int parent = -1; char *leaf = NULL; int e = parent_of(root, relative, 0, &parent, &leaf); if (e) return e;
    if (unlinkat(parent, leaf, flags) < 0) e = system_error();
    if (!e && fsync(parent) < 0) e = system_error();
    close(parent); free(leaf); return e;
}
int folio_remove_file(int root, const char *relative) { return remove_item(root, relative, 0); }
int folio_remove_directory(int root, const char *relative) { return remove_item(root, relative, AT_REMOVEDIR); }
int folio_acquire_lock(int root, const char *relative, int *lock_fd) {
    int parent = -1; char *leaf = NULL; int e = parent_of(root, relative, 0, &parent, &leaf); if (e) return e;
    int fd = openat(parent, leaf, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    if (fd < 0) e = system_error();
    struct stat s;
    if (!e && fstat(fd, &s) < 0) e = system_error();
    if (!e && (!S_ISREG(s.st_mode) || s.st_nlink != 1)) e = EINVAL;
    if (!e && flock(fd, LOCK_EX | LOCK_NB) < 0) e = system_error();
    close(parent); free(leaf);
    if (e) { if (fd >= 0) close(fd); } else *lock_fd = fd;
    return e;
}
void folio_sha256(const unsigned char *bytes, size_t length, unsigned char digest[32]) {
#if defined(__APPLE__)
    CC_SHA256(bytes, (CC_LONG)length, digest);
#else
    SHA256(bytes, length, digest);
#endif
}
