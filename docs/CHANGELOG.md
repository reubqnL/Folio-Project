# Fix — macOS core compile follow-up (2026-09-29)

## Fixed

- The first post-libarchive Mac compile exposed two additional portability defects: a malformed `var contents: [text]` declaration in the raw-HTML Markdown path and an unavailable `sqlite3_enable_load_extension` call. The parser declaration now uses the intended inferred `[String]` array, and the SQLite call is compiled only on non-Darwin platforms because Apple’s system SQLite is built with `SQLITE_OMIT_LOAD_EXTENSION`.

## Evidence

- On Apple Swift 6.3.2 / macOS 26 / arm64, `bash scripts/test-core.sh` now passes the libarchive compilation stage and reaches FolioCore compilation; this follow-up was made directly from the reported compiler output. A complete test run is still required after pulling this fix.

# Fix — macOS compile: vendored libarchive headers (2026-09-29)

## Fixed

- First Mac build attempt (Swift 6.3.2, macOS 26, Xcode 26) failed compiling `Sources/FolioRDMPrimitives/FolioArchive.c` with `'archive.h' file not found`: macOS ships the compiled system libarchive (the SDK exposes `libarchive.tbd`) but not its headers. Folio now compiles against a vendored, declaration-subset mirror of the libarchive 3.7.7 public headers (`Sources/FolioRDMPrimitives/vendor/libarchive/`, BSD-2-Clause; provenance and extension rules in its README) and links the system `libarchive` — no Homebrew or other installs needed on the Mac. Linux builds use the same headers and need the distro `libarchive` development package.
- The subset is private to `FolioRDMPrimitives` (`cSettings: .headerSearchPath("vendor/libarchive")`); every constant and prototype Folio uses is verbatim upstream, and `FolioArchive.c` compiles clean under `gcc -Wall -Wextra -Werror` against it.

## Notes

- App Store release note: App Review flags system-libarchive symbol references as non-public API. If Folio ever ships on the Mac App Store, switch to a statically built libarchive. Tracked as a release-track item (vendor README).

# Increment 12 — large-file/long-line benchmark harness (N02)

## Added

- `BenchmarkCorpora` + `BenchmarkStatistics` (`Sources/FolioCore/Markdown/MarkdownBenchmarks.swift`): deterministic, named benchmark inputs sized against `MarkdownLimits` — a realistic small note, 256 KB and near-budget (500 KB) mixed-construct notes, an over-budget note that must take the limitation/excerpt path, 16 lines of ~30K characters just under the line-length cap, 9,992 blocks just under the rendering budget, and a mixed-construct stress note (front matter, setext, tables with escapes, emoji, wikilinks). Names and shapes are evidence API so recorded measurements stay comparable across machines and runs.
- `FolioBenchmarkProbe` (`Sources/FolioBenchmarkProbe/`) — measures the editor-critical paths over those corpora: full parse, per-keystroke incremental reparse (allocation-honest, plus a splice-only figure on the near-budget note), link scan and excerpt. Warmups + repeated samples; median/p95/min printed as a table or `--json` machine-readable output. **Timings are printed, never asserted anywhere** — they become evidence only when recorded on the machine class that will sign the release (decision 26; decision 50 gives that gate no waiver path).
- `scripts/run-benchmarks.sh` — release-builds the probe and records `Evidence/benchmarks.json` (Evidence/ stays uncommitted; attach the JSON and machine details when crediting the gate).
- 9 focused tests (421 total in source): corpus determinism, unique names and exactly one edit marker per corpus, budget targeting (near-budget under the parse cap, over-budget over it, long lines under the line cap), parse outcomes on every corpus including the limitation path, incremental-vs-full parse equality on every corpus, link-scan span round-trips on the stress corpus, and the statistics definitions (median odd/even, nearest-rank p95, empty input never traps).

## Notes

- No measurements are recorded yet: this environment cannot build Swift. The harness is ready; `bash scripts/run-benchmarks.sh` on an Apple Silicon Mac produces the evidence for the `inputAndLargeDocumentCorrectness` release gate.

# Increment 11 — compact link repair (N02)

## Added

- `NoteLinkRepair` (`Sources/FolioCore/Markdown/NoteLinkRepair.swift`): broken and ambiguous note links are now visible and repairable (baseline §4.2; decision 12). Every authored note link is found at an exact source span with the exact semantics of the inline parser and the knowledge graph — code, literal HTML, metadata and rules never contribute; blocked, external and pure-anchor targets are not note links; escapes and images are excluded.
- A confirmed repair rewrites exactly one link's target — the label, the `|alias` and `#section` anchors keep the author's form (title links stay titles, path links stay paths) — and the original link is kept until the replacement is confirmed. Each edit is bound to the source digest it was computed against and refuses stale or mismatched application; a replacement that would not re-parse as a note link at the same site (embedded `]]`, `|`, `)` and similar) is refused, never half-applied.
- The compact repair sheet (decision 12 — folder path, tags and modification date per candidate) lists links with no matching note or several matching notes, with one explicit confirmation per replacement; a refusal never changes the note. Reachable as "Repair Note Links…" in the toolbar and the command palette (⌘⇧E, safely remappable).
- `repairLinks` joins the command catalog with the same safe-remapping policy as every other command (reserved keys, conflicts named, never silently rebound).
- 23 focused tests (412 total in source): scanner equivalence pinned against both `MarkdownInlineParser` targets and `GraphLinkExtractor` targets over an adversarial corpus (escapes, code spans, nested emphasis, labels, unclosed forms, duplicate links, table pipes and escapes, CRLF/emoji spans, block-kind policy), resolution inspection (missing/unique/ambiguous), form-preserving replacement text, single-occurrence rewrites, stale/span/blocked refusals, and repairs through headings, quotes, list items and table cells.

## Notes

- Occurrences whose authored target does not appear verbatim in the source (table-cell escape rewriting such as `[[x\|y]]` content) are not offered for repair — a repair must rewrite exactly what the author wrote. The scanner's recognition still matches the parser exactly; only the rewriteable set is narrower.
- A `]` inside a link label breaks the outer `[label](target)` form in this parser (the inner wikilink becomes a top-level link); the scanner and tests pin that exact behaviour rather than papering over it.

# Increment 10 — incremental Markdown reparse (N02)

## Added

- `MarkdownReparseSession` (`Sources/FolioCore/Markdown/MarkdownIncremental.swift`): the reading preview now re-parses only the changed region of a note per keystroke. A line-level diff bounds a reparse window; blocks outside it are spliced with their exact spans, content+occurrence identities and merged warnings, so untouched preview blocks keep stable `ForEach` identities and scroll anchors. The result is always parse-equal to `MarkdownParser.parse` on the same source — the splice is proven before use, and every unprovable case (limited parses, over-budget sources, full-document edits, changed block budgets) falls back to a full parse.
- Boundary proofs around the splice: a 2-line lookahead window floor (setext underlines and table alignment rows decide boundaries ahead), window-EOF proofs (`rule`/`listItem` at EOF can pair with a suffix line; blank-extension for open paragraphs/quotes/HTML; fence-close scan for unclosed code), straddle growth so no old block tail is dropped, and the front-matter scan treated as document-wide (an edit in the first 129 lines reparses from line 0; mid-document windows can never form metadata blocks).
- `MarkdownParser` internals restructured for the splice (`parseDetailed`/`project`/`splitLines`) with byte-identical public `parse`/`excerpt` output; the existing 23 parser tests cover the unchanged surface.
- The reading preview (`MarkdownPreviewView`) keeps one session per document and preview mode, runs `reparse` on a detached task away from the main actor, and rebuilds the session when excerpt mode toggles or the document changes.
- 23 focused tests: adversarial splice swallows (fence/table/quote), unclosed fences to EOF, closing fences appearing later, setext partner changes across the splice, front matter added/removed/inserted/never-suffix-reused, the two-line lookahead hazard, edit-then-undo, duplicate-block renumbering, untouched-block id stability, empty/CRLF/emoji sources, budget fallbacks, and a 4,000-block document where one edit reparses at most 6 blocks (timings printed, never asserted).
- Development evidence: the algorithm survived 32,000 randomized edit-sequence equivalence checks against full parses via an out-of-repository Python mirror (not shipped, not a substitute for the Swift test run).

# Increment 09 — honest durability acknowledgement (N01 contract)

## Added

- `VaultDurability` (`Sources/FolioCore/Storage/VaultDurability.swift`): the N01 seven-state acknowledgement model — `notCreated`, `loadedFromDisk`, `editsPending`, `writing`, `durableOnDisk`, `externalConflict`, `failed` — with honest labels, scoped explanations and `acknowledgesDurability` true only after the storage barrier is crossed. Queued or timed work can never be displayed as saved.
- `VaultCheckpointState` and `VaultRemoteState`: the contract's separation axes — `.rdm` archive construction is displayed apart from local durability (a stale archive is never described as up to date), and this build's missing sync is shown explicitly as "Local only — no sync" rather than implied.
- `SaveCoalescing` named, documented measurements: 250 ms edit debounce target and 500 ms bounded maximum delay after the first dirty edit; the docs state plainly that these schedule writes and do not acknowledge them.
- Editor status line now derives from the model (`OpenNoteDocument.durability`) with barrier-scoped help text; the notes status bar shows the remote-state axis. Encrypted workspace shows all three axes (working-copy draft durability, checkpoint state, sync) as one summary line with per-axis explanations, tracks confirmed vs pending working-copy writes with a generation guard so a superseded debounced write cannot confirm newer text, and reports checkpoint failures without discarding drafts.
- "Cancelling creates no file and no hidden draft on disk" is now stated on the new-note sheet (contract state 1).
- 10 focused tests: resolution/precedence matrix, label-honesty rules (only acknowledged states may say "Durable"/"Saved"), scoped explanations, checkpoint/remote separation wording, and measured coalescing bounds including a 40-edit continuous-typing simulation.

## Fixed

- Stale development captions: the launcher no longer calls the encrypted preview "memory-only"/"read-only" or Increment 07, the encrypted landing no longer lists the persistent encrypted index as a future gate, and the unlock notice no longer claims search results are unpersisted.

## Evidence and limits

The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures. This increment's sources and tests pass full swift-syntax parsing (110 Swift files, 0 syntax failures); the 10 new tests must run via `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. The storage barrier's APFS/power-loss behaviour remains unverified on Mac. This is not safe for sensitive data or release; plain-vault data remains plaintext.

---

# Increment 08 — persistent encrypted working storage

## Added

- `RDMWorkingStore`: unsaved encrypted-project drafts persist locally as two alternating AES-256-GCM sealed slot records (`.folio/<name>.rdmworking.0/1`) chained by generation and previous-record digest, written through the atomic `.folio` staging path with no plaintext residue.
- Fail-closed restore classification (`.empty` / `.current` / `.stale`): torn writes, missing history, single-slot rollback, mixed epochs and unauthenticated copies surface for explicit review and block further draft writes until a reviewed `resolve()` re-anchors a fresh epoch; set-aside bytes are preserved as private `.folio` copies rather than destroyed.
- Encrypted derived-index cache (`.folio/<name>.rdmindex`) bound to its archive snapshot; cache hits warm the search index on open, and every cache failure mode falls back to the in-memory rebuild without affecting search correctness.
- `RDMProjectSession` working-state API (`restoreWorkingState`, `stageDraft`, `discardDraft`, `resolveWorkingState`) with checkpoint-first, cache-second ordering.
- Native encrypted UI: 250 ms debounced draft staging into the encrypted working copy, restore of the most recent unsaved draft after unlock, local-draft discard after a successful checkpoint, an explicit "Review local working copies" action, and captions that describe the real draft/index behaviour.
- Focused tests for chaining/round trip, the stale-detection matrix, reviewed resolution with byte preservation, draft bounds/validation, plaintext canaries, index-cache round trip/corruption/snapshot binding, and session-level draft survive-close/reopen, discard, stale-block and cache fallback scenarios.

## Evidence and limits

The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures. This increment's sources and tests pass full swift-syntax parsing (108 Swift files, 0 syntax failures); the new test executions must run via `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. Mac SDK/CryptoKit/APFS, power-loss, Keychain, accessibility and independent security evidence remain blocked. This is not safe for sensitive data or release; plain-vault data remains plaintext.

---

# Increment 07 — encrypted `.rdm` foundation

## Added

- Pinned upstream Argon2id source with provenance/license notice and fixed bounded compatibility profile.
- Protected secret allocation/zeroing, AES-256-GCM/HKDF primitives and known-answer tests.
- Strict ZIP64 encrypted manifest/object envelope; no plaintext member names/content except the bounded clear header.
- Passphrase/recovery credential slots, authenticated object/manifest AAD, fresh snapshot/object revisions and parent lineage.
- Atomic `.rdm` file creation/checkpoint/open with lock and stale external-head protection.
- Bounded memory-only encrypted working index with close/delete erasure and no persistent plaintext cache/WAL.
- 56 passing encrypted primitive/archive/checkpoint/working-index/hostile-input/session tests; license/protocol contract retained.
- Encrypted project session and native encrypted-project preview/editor source with explicit recovery review, lock/close erasure, new-note creation, reviewed checkpoint-draft flow and non-destructive plain-to-encrypted-copy preparation with progress, cancellation and source-preservation failure handling.
- Encrypted archive creation now refuses any existing destination and has a regression test proving the sentinel bytes remain unchanged.
- Recorded full Debug/Release core runs at 333 tests with 0 failures.

## Still blocked

CryptoKit/Mac SDK parity, Keychain/device slots, persistent encrypted working/index/cache, hostile-input/fault coverage, APFS/power-loss, migrations, independent security review and native encrypted workspace UI. This is not safe for sensitive data or release. Existing plain-vault data remains plaintext.

---

# Increment 06 — explicit on-device voice capture

## Added

- Separate asset-download and Record/microphone consent, project/capture-bound voice state and explicit stop/finalization acknowledgement.
- Bounded transcript assembly, provisional/final handling, correction, partial-warning approval and stale-safe handoff to Capture.
- Preallocated SPSC PCM queue with overflow/format/reentrancy guards and stopped-buffer clearing.
- Native macOS-26 AVAudioEngine/SpeechAnalyzer/SpeechTranscriber source; bounded conversion/input streaming, lifecycle observers and teardown.
- Recorder/review UI, visible microphone indicator, purpose string and audio-input entitlement. No cloud fallback or raw recording file store.
- Synthetic speech workflow and ASan/UBSan C queue harness; referenced Apple sample license preserved.

## Evidence and remaining gates

277 unit tests pass in Debug/Release on Linux; 69 workflow/process scenarios and 6 separate audio sanitizer checks pass. No actual Mac microphone/recognition/teardown or live model evaluation ran. Native SDK, privacy, accuracy, real-time performance and independent review remain blocked.

The weighted estimate is 40%, not a security score. Owner testing remains held. No percentage increase waives a blocker.

---

# Increment 05 — explicit-context capture and review

## Added and checked

- Frozen context selection, transcript confirmation and profile-bounded request preparation.
- A text-only broker with single-operation ownership, deadline/cancellation handling and rejected late results.
- Whole-draft/section/line-change review, bound selections, Unicode/front-matter protections, fresh approvals after rebase/edit, and stale-safe apply/undo plans.
- A deterministic 250-case diff reconstruction corpus plus provider, scope, selection and cancellation tests.
- Native composer/review/editor-transaction source and an Apple on-device provider adapter with no tools or cloud fallback.
- A generated capture-to-storage probe clearly labelled as a fixed provider fixture, not LLM execution.
- A weighted progress ledger: 38% estimated implementation/planning completion, with release/security readiness still blocked.

## Evidence and limits

235 unit tests pass in Debug/Release on Linux. 57 generated workflow/process checks pass, including 11 capture checks. Native SDK/LLM/editor behaviour is unverified. No speech recording, encrypted `.rdm`, collaboration or installer/update release is claimed. Prompt/data separation is not a claim of perfect prompt-injection resistance.

The owner's requirement remains: no rushed work, and no owner testing before the approved feature set and mandatory gates are complete.

---

# Increment 04 — linked planning and connections

## Added

- Date-only task/milestone model, Timeline/Unscheduled/Kanban projections, stable note links and dependency graph.
- Explicit proposal validation/repair, bulk moves, ordering, deletion and session undo/redo with fresh revisions and content checks.
- Versioned roadmap persistence inside the vault actor, sealed transactions, conflicts and crash recovery.
- Shared authored-link graph, missing-link disclosure, one/two-hop scope, bounded clustering, deterministic layout, picking and opt-in 3D projection.
- Native planning, task editing, dependency inspection, graph/list/selection source and MetalKit on-demand rendering with separate in-flight vertex buffers.
- New typed commands and generated planning/SIGKILL probes.

## Verified here

180 tests in Debug and Release on Linux; 13 note-process, 12 roadmap-process, 11 reading and 10 planning/graph workflow checks. Mac source is syntax-parsed, not SDK/GPU/runtime tested.

## Delivery and cleanup

Owner testing is held until the approved Mac feature set and mandatory engineering gates are complete. Historical duplicate exports, obsolete tooling and old incremental ZIPs were removed; one current `Folio-Source.zip` replaces the archive pile. Source, all 50 decisions, useful evidence/design references and the unchanged logo were preserved.

AI/speech, encryption/container, collaboration, installer/updater and native/security validation remain unfinished. This is not a released or feature-complete app.

---

# Increment 03 — reading, search and commands

## Added

- A disposable, workspace-bound SQLite FTS5 cache outside the vault, literal/phrase/prefix queries, title-first ranking, tag scopes and plain-text excerpts.
- Transactionally maintained external-content FTS rows, stale-update reservations, rebuild generations, bounded query work and explicit cache disposal/rebuild.
- Search-resource profiles with actual SQLite page-cache settings.
- Bounded UTF-16-mapped Markdown block/inline parsing and native SwiftUI preview source; explicit Follow cursor and excerpt consent.
- Literal HTML, non-loading image placeholders, safe external-link confirmation, known-note-only wikilinks and ambiguity chooser source.
- A separate typed command palette and remappable Folio shortcuts protecting native editing/system/accessibility chords.
- Source/Preview/Split source layout retaining the native editor, in-note Find wiring and IME provisional-text guards.
- Constant-time note-ID lookup and indexed missing-path rename matching in the vault store.

## Evidence

137 unit tests in Debug and Release, 13 process/storage checks and 11 generated 1,000-note reading-workflow checks. All execution evidence is Linux/core scope. Mac source is syntax-parsed, not SDK-typechecked or runtime-validated.

## Still blocked

Full native UI/input/undo/accessibility and APFS evidence; complete Markdown dialect support; 100k-note/energy/memory/frame budgets; recursive reconciliation; independent security and distribution gates. Graph, planning, AI/speech, encryption/sync and installer/updater are still later work.

Historical source ZIPs were subsequently superseded and removed under the workspace-cleanup request.

---

# Increment 02 — local project storage

## Added

- A real, actor-isolated plain-vault store and bounded POSIX file-I/O layer.
- Explicit project initialisation, stable IDs, note creation/open/save, safe relative path handling and a single-Folio-writer lock.
- Staged journals, flushed payloads, non-clobbering creation and atomic exchange with retained displaced bytes.
- Conflict preservation, review-only drafts, idempotent recovery, committed-history bounds and journal quotas.
- Byte-preserving UTF-8 import, unknown-schema rejection, read-only protection and supported file-metadata copying.
- Native folder-picker/grant integration, project explorer, bounded autosave, explicit Save, conflict/recovery views and save-aware quit source.
- Active-file/parent observation; filename picker/filter; source-selection retention and external-reload undo resets.
- A developer storage probe, reproducible core test scripts and real process-kill tests.

## Verified in this environment

- Swift 6.0.3 Linux compilation of the core, C I/O target and probe.
- 73 unit tests in both Debug and Release configurations; 13 process/storage scenarios.
- C compiler warning/static-analysis checks and syntax parsing of the Mac Swift source.
- Approved logo identity unchanged.

## Important fixes while building

- Async XCTest discovery now uses stateless test containers compatible with Linux Swift 6; the production actor boundaries remain intact.
- Recovery never automatically overwrites a changed/read-only head, replays a review-only proposal or rolls back a later edit from a committed record.
- Copied projects can quarantine pending old proposals before receiving a new identity.
- New typing after a conflict is preserved before Use Disk Version can discard the editing buffer.
- A changed comparison is presented again before Keep My Text proceeds.
- The autosave path retains a follow-up wakeup if a previous write is still finishing.
- Ownership/mode and supported xattrs/ACLs are copied rather than silently dropped; Linux destination-only inherited xattrs are removed.
- Invalid resource limits and extreme filesystem timestamps are bounded.

## Still not approved for release

The Mac target is not built or runtime-tested. Native IME/undo/accessibility, recursive filesystem reconciliation, APFS barriers/metadata, real power-loss and fault-matrix testing, large-vault performance, security audit, signing/notarization and installer/updater gates are outstanding. Graph/planning/AI/speech/encryption/sync remain unimplemented.

The active `native/` tree is the source of truth; old incremental ZIPs were subsequently superseded and removed under the cleanup request.
