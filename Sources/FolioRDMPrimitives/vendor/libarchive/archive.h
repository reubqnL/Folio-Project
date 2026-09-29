/*-
 * Vendored API-subset mirror of libarchive's public <archive.h>.
 *
 * Provenance: declarations and constants below are verbatim excerpts of
 * libarchive 3.7.7 (https://github.com/libarchive/libarchive), file
 * libarchive/archive.h, retrieved 2026-09-29. Unused declarations and
 * Windows-specific branches have been removed; nothing else was altered.
 * If more libarchive API is needed, extend from upstream keeping the
 * declarations verbatim (see README.md in this directory).
 *
 * Copyright (c) 2003-2010 Tim Kientzle
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

#ifndef ARCHIVE_H_INCLUDED
#define	ARCHIVE_H_INCLUDED

/*
 * The version number mirrors the upstream header this subset was taken
 * from; it identifies the header API level, not the runtime library
 * (use archive_version_string() for the linked library).
 */
#define	ARCHIVE_VERSION_NUMBER 3007007

#include <stddef.h>
#include <stdint.h>
#include <unistd.h> /* ssize_t */

/* Get appropriate definitions of 64-bit integer (POSIX branch upstream). */
#if !defined(__LA_INT64_T_DEFINED)
#define __LA_INT64_T_DEFINED
typedef int64_t la_int64_t;
#endif

/* The la_ssize_t should match the type used in 'struct stat'. */
#if !defined(__LA_SSIZE_T_DEFINED)
#define __LA_SSIZE_T_DEFINED
typedef ssize_t la_ssize_t;
#endif

/* Static libraries or non-Windows needs no special declaration. */
#define __LA_DECL

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The version number is provided as both a macro and a function.
 * The macro identifies the installed header; the function identifies
 * the library version (which may not be the same if you're using a
 * dynamically-linked version of the library).
 */
__LA_DECL int		archive_version_number(void);

/*
 * Textual name/version of the library, useful for version displays.
 */
__LA_DECL const char *
		archive_version_string(void);

/* Declare our basic types. */
struct archive;
struct archive_entry;

/*
 * Error codes: Use archive_errno() and archive_error_string()
 * to retrieve details.  Unless specified otherwise, all functions
 * that return 'int' use these codes.
 */
#define	ARCHIVE_EOF	  1	/* Found end of archive. */
#define	ARCHIVE_OK	  0	/* Operation was successful. */
#define	ARCHIVE_RETRY	(-10)	/* Retry might succeed. */
#define	ARCHIVE_WARN	(-20)	/* Partial success. */
/* For example, if write_header "fails", then you can't push data. */
#define	ARCHIVE_FAILED	(-25)	/* Current operation cannot complete. */
/* But if write_header is "fatal," then this archive is dead and useless. */
#define	ARCHIVE_FATAL	(-30)	/* No more operations are possible. */

/*
 * Codes to identify various stream filters.
 */
#define	ARCHIVE_FILTER_NONE	0

/*
 * Codes returned by archive_format.
 *
 * Top 16 bits identifies the format family (e.g., "tar"); lower
 * 16 bits indicate the variant.  This is updated by read_next_header.
 */
#define	ARCHIVE_FORMAT_BASE_MASK		0xff0000
#define	ARCHIVE_FORMAT_ZIP			0x50000

/*
 * Codes returned by archive_read_has_encrypted_entries().
 *
 * In case the archive does not support encryption detection at all
 * ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED is returned. If the reader
 * for some other reason (e.g. not enough bytes read) cannot say if
 * there are encrypted entries, ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW
 * is returned.
 */
#define ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED -2
#define ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW -1

/* Basic outline for reading an archive is documented upstream; the
 * subset below covers the calls Folio's .rdm archive layer uses. */
__LA_DECL struct archive	*archive_read_new(void);

__LA_DECL int archive_read_support_filter_none(struct archive *);
/* archive_read_support_format_zip() enables both streamable and seekable
 * zip readers. */
__LA_DECL int archive_read_support_format_zip(struct archive *);

/* Read an archive that's stored in memory. */
__LA_DECL int archive_read_open_memory(struct archive *,
		     const void * buff, size_t size);

/* Parses and returns next entry header. */
__LA_DECL int archive_read_next_header(struct archive *,
		     struct archive_entry **);

/*
 * Returns 1 if the archive contains at least one encrypted entry.
 * If the archive format not support encryption at all
 * ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED is returned.
 * If for any other reason (e.g. not enough data read so far)
 * we cannot say whether there are encrypted entries, then
 * ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW is returned.
 * In general, this function will return values below zero when the
 * reader is uncertain or totally incapable of encryption support.
 * When this function returns 0 you can be sure that the reader
 * supports encryption detection but no encrypted entries have
 * been found yet.
 */
__LA_DECL int	archive_read_has_encrypted_entries(struct archive *);

/* Read data from the body of an entry.  Similar to read(2). */
__LA_DECL la_ssize_t		archive_read_data(struct archive *,
				    void *, size_t);

/* Close the file and release most resources. */
__LA_DECL int		 archive_read_close(struct archive *);
/* Release all resources and destroy the object. */
/* Note that archive_read_free will call archive_read_close for you. */
__LA_DECL int		 archive_read_free(struct archive *);

/*-
 * To create an archive:
 *   1) Ask archive_write_new for an archive writer object.
 *   2) Set any global properties.  In particular, you should set
 *      the compression and format to use.
 *   3) Call archive_write_open to open the file.
 *   4) For each entry:
 *      - construct an appropriate struct archive_entry structure
 *      - archive_write_header to write the header
 *      - archive_write_data to write the entry data
 *   5) archive_write_close to close the output
 *   6) archive_write_free to cleanup the writer and release resources
 */
__LA_DECL struct archive	*archive_write_new(void);

/* A convenience function to set the format based on the code or name. */
__LA_DECL int archive_write_set_format_zip(struct archive *);

/* _buffSize is the size of the buffer, _used refers to a variable that
 * will be updated after each write into the buffer. */
__LA_DECL int archive_write_open_memory(struct archive *,
		    void *_buffer, size_t _buffSize, size_t *_used);

/*
 * Note that the library will truncate writes beyond the size provided
 * to archive_write_header or pad if the provided data is short.
 */
__LA_DECL int archive_write_header(struct archive *,
		     struct archive_entry *);
__LA_DECL la_ssize_t	archive_write_data(struct archive *,
			    const void *, size_t);

__LA_DECL int		 archive_write_finish_entry(struct archive *);
__LA_DECL int		 archive_write_close(struct archive *);
/* This can fail if the archive wasn't already closed, in which case
 * archive_write_free() will implicitly call archive_write_close(). */
__LA_DECL int		 archive_write_free(struct archive *);

/*
 * Set write options.
 */
/* Apply option to the format only. */
__LA_DECL int archive_write_set_format_option(struct archive *_a,
			    const char *m, const char *o,
			    const char *v);

/*
 * Accessor functions to read/set various information in
 * the struct archive object:
 */

/* Number of filters in the current filter pipeline. */
/* Filter #0 is the one closest to the format, -1 is a synonym for the
 * last filter, which is always the pseudo-filter that wraps the
 * client callbacks. */
__LA_DECL int		 archive_filter_code(struct archive *, int);

/* Details about the format used. */
__LA_DECL int		 archive_format(struct archive *);

#ifdef __cplusplus
}
#endif

/* These are meaningless outside of this header. */
#undef __LA_DECL

#endif /* !ARCHIVE_H_INCLUDED */
