/*-
 * Vendored API-subset mirror of libarchive's public <archive_entry.h>.
 *
 * Provenance: declarations and constants below are verbatim excerpts of
 * libarchive 3.7.7 (https://github.com/libarchive/libarchive), file
 * libarchive/archive_entry.h, retrieved 2026-09-29. Unused declarations
 * and Windows-specific branches have been removed; nothing else was
 * altered. If more libarchive API is needed, extend from upstream keeping
 * the declarations verbatim (see README.md in this directory).
 *
 * Copyright (c) 2003-2008 Tim Kientzle
 * Copyright (c) 2016 Martin Matuska
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef ARCHIVE_ENTRY_H_INCLUDED
#define	ARCHIVE_ENTRY_H_INCLUDED

/*
 * The version number mirrors the upstream header this subset was taken
 * from; it must match archive.h (see upstream note: "Compiler will
 * complain if this does not match archive.h!").
 */
#define	ARCHIVE_VERSION_NUMBER 3007007

#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

/* Get a suitable 64-bit integer type (POSIX branch upstream). */
#if !defined(__LA_INT64_T_DEFINED)
#define __LA_INT64_T_DEFINED
typedef int64_t la_int64_t;
#endif

/* The la_ssize_t should match the type used in 'struct stat'. */
#if !defined(__LA_SSIZE_T_DEFINED)
#define __LA_SSIZE_T_DEFINED
typedef ssize_t la_ssize_t;
#endif

/* Get a suitable definition for mode_t (libarchive 3.x branch upstream). */
#define	__LA_MODE_T	mode_t

/* Static libraries on all platforms and shared libraries on non-Windows. */
#define __LA_DECL

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Description of an archive entry.
 *
 * You can think of this as "struct stat" with some text fields added in.
 */
struct archive;
struct archive_entry;

/*
 * File-type constants.  These are returned from archive_entry_filetype()
 * and passed to archive_entry_set_filetype().
 *
 * These values match S_XXX defines on every platform I've checked,
 * including Windows, AIX, Linux, Solaris, and BSD.  They're
 * (re)defined here because platforms generally don't define the ones
 * they don't support.
 */
#define AE_IFMT		((__LA_MODE_T)0170000)
#define AE_IFREG	((__LA_MODE_T)0100000)
#define AE_IFLNK	((__LA_MODE_T)0120000)
#define AE_IFSOCK	((__LA_MODE_T)0140000)
#define AE_IFCHR	((__LA_MODE_T)0020000)
#define AE_IFBLK	((__LA_MODE_T)0060000)
#define AE_IFDIR	((__LA_MODE_T)0040000)
#define AE_IFIFO	((__LA_MODE_T)0010000)

/*
 * Basic object manipulation
 */

__LA_DECL void			archive_entry_free(struct archive_entry *);
__LA_DECL struct archive_entry	*archive_entry_new(void);

/*
 * Retrieve fields from an archive_entry.
 *
 * In addition, fields can be "set" or "unset."  Unset string fields
 * return NULL, non-string fields have _is_set() functions to test
 * whether they've been set.
 */
__LA_DECL __LA_MODE_T	 archive_entry_filetype(struct archive_entry *);
__LA_DECL const char	*archive_entry_hardlink(struct archive_entry *);
__LA_DECL const char	*archive_entry_pathname(struct archive_entry *);
__LA_DECL la_int64_t	 archive_entry_size(struct archive_entry *);
__LA_DECL int		 archive_entry_size_is_set(struct archive_entry *);
__LA_DECL const char	*archive_entry_symlink(struct archive_entry *);
__LA_DECL int archive_entry_is_data_encrypted(struct archive_entry *);
__LA_DECL int archive_entry_is_metadata_encrypted(struct archive_entry *);
__LA_DECL int archive_entry_is_encrypted(struct archive_entry *);

/*
 * Set fields in an archive_entry.
 *
 * Note: Before libarchive 2.4, there were 'set' and 'copy' versions
 * of the string setters.  'copy' copied the actual string, 'set' just
 * stored the pointer.  In libarchive 2.4 and later, strings are
 * always copied.
 */

__LA_DECL void	archive_entry_set_filetype(struct archive_entry *, unsigned int);
__LA_DECL void	archive_entry_set_gid(struct archive_entry *, la_int64_t);
__LA_DECL void	archive_entry_set_mtime(struct archive_entry *, time_t, long);
__LA_DECL void	archive_entry_set_pathname(struct archive_entry *, const char *);
__LA_DECL void	archive_entry_set_perm(struct archive_entry *, __LA_MODE_T);
__LA_DECL void	archive_entry_set_size(struct archive_entry *, la_int64_t);
__LA_DECL void	archive_entry_set_uid(struct archive_entry *, la_int64_t);

#ifdef __cplusplus
}
#endif

/* These are meaningless outside of this header. */
#undef __LA_DECL

#endif /* !ARCHIVE_ENTRY_H_INCLUDED */
