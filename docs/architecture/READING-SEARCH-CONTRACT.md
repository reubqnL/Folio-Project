# Reading, search and commands — Increment 03

## Search is derived, not authoritative

`LocalSearchIndex` is an actor-isolated SQLite FTS5 cache for **plaintext vaults only**. Markdown and authored `.folio` metadata remain authoritative. A cache failure does not turn a successful file save into a failure, and cached excerpts are never written back to notes. Opening a result reads the current note through the vault store.

The Mac source places the cache in the application's private `Caches/Folio/Search` directory, outside the selected vault. Cache filenames bind the project UUID and root identity. The database, WAL and shared-memory sidecars must not be moved independently or included in vault sync. They contain plaintext note text/tags, not ciphertext. Encrypted projects must use a separately reviewed index implementation; this one is not suitable for them.

### Query and index rules

- One search view covers titles, paths, tags and note bodies; the command palette is separate.
- Queries are bounded literal terms and quoted phrases, with a prefix match on the final unquoted term. Raw SQL/FTS operators are not accepted as a query language.
- All user values are bound parameters. Results are plain text, not executable HTML.
- Exact/prefix title matches take priority, followed by weighted FTS5 relevance, date and path.
- English/general-note relevance is the initial target. `unicode61 remove_diacritics 2` and prefix indexes are not a claim of language-specific quality for all scripts.
- Only a bounded front-matter tag subset is extracted: a scalar, inline list or simple indented list. YAML is not executed or rewritten. Complete YAML semantics are not implemented.
- FTS5 external-content rows and the `docs` cache table update in one transaction; insert/update/delete and external-content integrity checks are tested.
- A reservation taken before reading invalidates older in-flight updates. A superseded rebuild cannot finish/purge the current generation.
- An incomplete/cancelled rebuild does not purge unseen rows. Completion purges absent entries. Results may be incomplete/stale during rebuilding or after unobserved external changes; the UI shows indexing/error state and offers Rebuild.
- Live saves and detected external changes update the cache asynchronously. This is eventual search consistency, not a global filesystem snapshot or sync protocol.
- Core queries have input/result/offset bounds and SQLite progress/deadline cancellation. Configured cache sizes are 4, 16 or 32 MiB for the three profiles; these are **SQLite page-cache settings**, not total process-memory guarantees.
- Explicit cache reset closes the handle and unlinks only the deterministic database/sidecar filenames. It cannot recursively delete a directory. Notes and journals are not touched.

SQLite comes from the system library/SDK, not a bundled web stack. FTS5 availability and owned schema/binding checks happen at open. The schema has no executable user-defined extensions; extension loading is disabled and trusted-schema mode is off.

## Native reading preview

The core produces a bounded, source-mapped Markdown block model. The Mac source renders it using SwiftUI text/native controls—**no WKWebView or HTML importer**.

Supported subset:

- ATX/Setext headings, paragraphs, rules and quotes;
- fenced code with language labels;
- basic ordered/unordered/task list items;
- bounded pipe tables;
- inline emphasis, strong, strike and code;
- Markdown links and aliased wikilinks;
- a collapsible literal front-matter block.

This is not full CommonMark/GFM conformance. Nested/multiline list layout, complex delimiter rules, reference links, footnotes, link titles, escaping edge cases and richer tables remain refinement work. Unsupported input is generally literal, not interpreted as code.

Raw HTML is displayed literally. Images are placeholders and never auto-fetch local or remote content. Only http/https/mailto links can request an external opener, with a confirmation first; credential-bearing, control-character, file/data/javascript and escaping targets are blocked. Wikilinks resolve only against known note IDs in the current project. Duplicate bare titles use a compact chooser with path, known tags and modification date. No missing target is automatically created or opened outside the vault.

### Cursor and view contract

- Source remains mounted in Source/Preview/Split in the Mac source; mode changes must not destroy its `NSTextView` or undo manager.
- Source selection is the anchor. There is no automatic scroll coupling.
- Only an explicit **Follow cursor** request moves the preview, using UTF-16 block ranges compatible with native selection offsets. Tables/fences map to their block, not a fabricated exact visual character position.
- External reloads reset stale undo; ordinary preview rendering does not mutate or save the source.
- Unchanged preview blocks have content/occurrence-based view identity even when earlier text moves their source ranges.
- Rendering runs off the main actor with debounce/cancellation and stale-result checks.
- Oversized notes/lines ask for an explicit excerpt choice; the source editor is never silently truncated. Default preview caps are 512 KiB UTF-8, 32K UTF-16 units per line and 10,000 blocks. Explicit excerpts stop at byte/grapheme/line limits. Tables render at most 12 columns/200 rows as a table, with overflow disclosure.

These are implemented policies/core models and Mac source design. Actual view identity, native IME composition, selection/undo continuity, keyboard focus, rendering accessibility and performance still require Mac runtime proof.

## Commands and shortcuts

The palette searches a fixed typed command registry, not note contents. Notes cannot define executable commands. Every dispatch checks its project/note/busy context again. Unimplemented FolioDev capabilities are not executable palette actions.

Default project search is **⌘⇧F**, the command palette is **⌘⇧P**, and source/preview/split use **⌘⌥1/2/3**. **⌘F** stays native in-note Find in source/split. Preview Follow cursor defaults to **⌘⌥L**.

Folio Settings can remap Folio commands. The validator rejects duplicate assignments, invalid keys, protected native editing/navigation shortcuts and the Control-Option VoiceOver chord. This is not discovery of every third-party/system shortcut; real Mac conflict/focus testing remains necessary.

## Evidence boundary

Linux core tests cover query handling, ranking, update/delete consistency, cache boundaries/reset, stale indexing leases, bounded queries, source mapping, parser safety/subset behaviour, link resolution and shortcut policy. A generated 1,000-note workflow uses the actual vault store, index and parser.

The recorded timings are smoke-test observations on that Linux fixture, **not** M1/8 GB, 100k-note, battery, FPS or large-document release certification. Mac SDK compilation, native accessibility/input/undo, APFS behaviour, signing/notarization and independent security gates remain open.
