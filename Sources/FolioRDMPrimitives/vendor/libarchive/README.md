# Vendored libarchive header subset

These two headers are a **declaration subset** of libarchive's public
`archive.h` / `archive_entry.h`, taken verbatim from **libarchive 3.7.7**
(`<https://github.com/libarchive/libarchive>`, files `libarchive/archive.h`
and `libarchive/archive_entry.h`, retrieved 2026-09-29). Unused
declarations and Windows-only branches were removed; every constant value
and function prototype used by Folio is byte-identical to upstream.

## Why this exists

Folio's `.rdm` container is written and read through libarchive's ZIP
support (`FolioArchive.c`). macOS **ships the compiled libarchive** (the
SDK exposes `libarchive.tbd`) but deliberately does **not** ship its
headers — a well-known gap (see `https://developer.apple.com/forums/thread/706711`).
To keep Mac builds zero-setup, Folio compiles against this vendored header
subset and links the system `libarchive` (`-larchive`). Linux builds use
the same headers and link the distro `libarchive` package.

Do not add these directories to any public header search path; they are
private to `FolioRDMPrimitives` via `cSettings: .headerSearchPath(...)`.

## Rules for changing this directory

1. Never edit a declaration or constant without copying the change from
   upstream `libarchive` headers verbatim — ABI mismatches fail silently.
2. If more libarchive API is needed, extend the subset from the upstream
   headers (same version or newer; record the version + date here).
3. Keep the license text intact (BSD-2-Clause, see `LICENSE`).

## Release note

Linking the system libarchive is fine for direct distribution and
development. If Folio ever ships on the Mac App Store, App Review flags
system-libarchive symbol references as non-public API; the accepted
remedy is to build libarchive statically and link that instead. Tracked
as a release-track item; not required for current builds.
