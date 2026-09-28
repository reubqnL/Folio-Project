#ifndef FOLIO_FILE_IO_H
#define FOLIO_FILE_IO_H
#include "FolioAudioRing.h"
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t device, inode, size;
    int64_t modified_ns, changed_ns;
    uint32_t permissions;
    int kind; /* 1 = regular, 2 = directory, 3 = symlink/other */
} FolioFileInfo;

typedef struct {
    char *name;
    FolioFileInfo info;
} FolioDirectoryEntry;

/* All operations return an errno value (0 on success), except root open,
   which returns a descriptor or -1 and sets errno. Relative paths are walked
   component-by-component from the pinned root with O_NOFOLLOW. */
int folio_open_root(const char *path);
void folio_close_fd(int fd);
int folio_last_errno(void);
int folio_root_info(int root, FolioFileInfo *info);
int folio_make_directory(int root, const char *relative);
int folio_read_file(int root, const char *relative, size_t limit,
                    unsigned char **bytes, size_t *length, FolioFileInfo *info);
void folio_free_bytes(void *bytes);
int folio_write_new(int root, const char *relative, const unsigned char *bytes,
                    size_t length, uint32_t permissions);
int folio_stat_file(int root, const char *relative, FolioFileInfo *info);
int folio_list_directory(int root, const char *relative, size_t limit,
                         FolioDirectoryEntry **entries, size_t *count);
void folio_free_entries(FolioDirectoryEntry *entries, size_t count);
/* Atomic install without clobbering an existing destination; leaves source. */
int folio_link_new(int root, const char *source, const char *destination);
/* Atomic exchange: displaced destination remains at source, never discarded. */
int folio_exchange(int root, const char *source, const char *destination);
int folio_copy_metadata(int root, const char *source, const char *destination);
int folio_sync_parent(int root, const char *relative);
int folio_remove_file(int root, const char *relative);
int folio_remove_directory(int root, const char *relative);
int folio_acquire_lock(int root, const char *relative, int *lock_fd);
void folio_sha256(const unsigned char *bytes, size_t length, unsigned char digest[32]);
#endif
