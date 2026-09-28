#define _GNU_SOURCE 1
#include "FolioRDMPrimitives.h"
#include <archive.h>
#include <archive_entry.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static int valid_name(const char *name) {
    if (!name) return 0;
    size_t length = strnlen(name, 100);
    if (!strcmp(name, "header.json") || !strcmp(name, "manifest.enc")) return 1;
    if (length != 72 || strncmp(name, "objects/", 8)) return 0;
    for (size_t i = 8; i < 72; i++) if (!((name[i] >= '0' && name[i] <= '9') || (name[i] >= 'a' && name[i] <= 'f'))) return 0;
    return 1;
}
void folio_rdm_bytes_free(void *p) { free(p); }
void folio_rdm_zip_free(FolioZipMember *members, size_t count) {
    if (!members) return;
    for (size_t i = 0; i < count; i++) { free(members[i].name); free(members[i].bytes); }
    free(members);
}
int folio_rdm_zip_write(const FolioZipMember *members, size_t count, size_t maximum_bytes,
                        unsigned char **output, size_t *output_length) {
    if (!output || !output_length) return 0;
    *output = NULL; *output_length = 0;
    if (!members || count < 2 || count > 10000 || maximum_bytes > 128 * 1024 * 1024) return 0;
    size_t capacity = 4096 + count * 512;
    for (size_t i = 0; i < count; i++) {
        if (!valid_name(members[i].name) || (members[i].length && !members[i].bytes) || members[i].length > maximum_bytes) return 0;
        if (capacity > maximum_bytes - members[i].length) return 0;
        capacity += members[i].length;
        for (size_t j = 0; j < i; j++) if (!strcmp(members[i].name, members[j].name)) return 0;
    }
    unsigned char *bytes = malloc(capacity); if (!bytes) return 0;
    struct archive *a = archive_write_new(); if (!a) { free(bytes); return 0; }
    size_t written = 0; int ok = 0;
    if (archive_write_set_format_zip(a) != ARCHIVE_OK ||
        archive_write_set_format_option(a, "zip", "compression", "store") != ARCHIVE_OK ||
        archive_write_set_format_option(a, "zip", "zip64", "1") != ARCHIVE_OK ||
        archive_write_open_memory(a, bytes, capacity, &written) != ARCHIVE_OK) goto done;
    for (size_t i = 0; i < count; i++) {
        struct archive_entry *entry = archive_entry_new(); if (!entry) goto done;
        archive_entry_set_pathname(entry, members[i].name);
        archive_entry_set_filetype(entry, AE_IFREG); archive_entry_set_perm(entry, 0600);
        archive_entry_set_uid(entry, 0); archive_entry_set_gid(entry, 0);
        archive_entry_set_mtime(entry, 0, 0); archive_entry_set_size(entry, (la_int64_t)members[i].length);
        int header = archive_write_header(a, entry); archive_entry_free(entry);
        if (header != ARCHIVE_OK) goto done;
        size_t offset = 0;
        while (offset < members[i].length) {
            la_ssize_t n = archive_write_data(a, members[i].bytes + offset, members[i].length - offset);
            if (n <= 0) goto done;
            offset += (size_t)n;
        }
        if (archive_write_finish_entry(a) != ARCHIVE_OK) goto done;
    }
    if (archive_write_close(a) != ARCHIVE_OK || written > maximum_bytes) goto done;
    *output = bytes; *output_length = written; bytes = NULL; ok = 1;
done:
    archive_write_free(a); free(bytes); return ok;
}
int folio_rdm_zip_read(const unsigned char *data, size_t length,
                       size_t maximum_entries, size_t maximum_member_bytes, size_t maximum_total_bytes,
                       FolioZipMember **members, size_t *count) {
    if (!members || !count) return 0;
    *members = NULL; *count = 0;
    if (!data || length < 22 || length > 128 * 1024 * 1024 || maximum_entries < 2 || maximum_entries > 10000 ||
        maximum_member_bytes > 64 * 1024 * 1024 || maximum_total_bytes > 128 * 1024 * 1024) return 0;
    struct archive *a = archive_read_new(); if (!a) return 0;
    FolioZipMember *result = calloc(maximum_entries, sizeof(*result)); if (!result) { archive_read_free(a); return 0; }
    size_t used = 0, total = 0; int ok = 0;
    if (archive_read_support_filter_none(a) != ARCHIVE_OK || archive_read_support_format_zip(a) != ARCHIVE_OK ||
        archive_read_open_memory(a, data, length) != ARCHIVE_OK) goto done;
    for (;;) {
        struct archive_entry *entry = NULL;
        int status = archive_read_next_header(a, &entry);
        if (status == ARCHIVE_EOF) break;
        if (status != ARCHIVE_OK || used >= maximum_entries || !entry) goto done;
        if ((archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) != ARCHIVE_FORMAT_ZIP || archive_filter_code(a, 0) != ARCHIVE_FILTER_NONE) goto done;
        const char *name = archive_entry_pathname(entry);
        if (!valid_name(name) || archive_entry_filetype(entry) != AE_IFREG || archive_entry_symlink(entry) ||
            archive_entry_hardlink(entry) || archive_entry_is_encrypted(entry) == 1 || !archive_entry_size_is_set(entry)) goto done;
        for (size_t i = 0; i < used; i++) if (!strcmp(name, result[i].name)) goto done;
        la_int64_t claimed = archive_entry_size(entry);
        if (claimed < 0 || (uint64_t)claimed > maximum_member_bytes || (uint64_t)claimed > maximum_total_bytes - total) goto done;
        size_t size = (size_t)claimed;
        result[used].name = strdup(name); result[used].bytes = malloc(size ? size : 1); result[used].length = size;
        if (!result[used].name || !result[used].bytes) { used++; goto done; }
        used++;
        size_t offset = 0;
        while (offset < size) {
            la_ssize_t n = archive_read_data(a, result[used-1].bytes + offset, size - offset);
            if (n <= 0) goto done;
            offset += (size_t)n;
        }
        unsigned char extra;
        if (archive_read_data(a, &extra, 1) != 0) goto done;
        total += size;
    }
    if (used < 2 || archive_read_has_encrypted_entries(a) == 1 || archive_read_close(a) != ARCHIVE_OK) goto done;
    *members = result; *count = used; result = NULL; ok = 1;
done:
    archive_read_free(a); folio_rdm_zip_free(result, used); return ok;
}
const char *folio_archive_backend_version(void) { return archive_version_string(); }
