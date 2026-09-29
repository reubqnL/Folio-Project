# Folio — completion estimate and evidence

**Estimated completion: 46% · Release readiness: blocked · Owner testing: HOLD**

Subjective weighted planning estimate; not verified security/correctness, percentage of code, or a release certificate.

| Area | Scope weight | Credited points |
|---|---:|---:|
| Product/design/decisions | 5 | 5 |
| Notes, project storage and search | 20 | 13 |
| Native editing, reading and accessibility | 15 | 10 |
| Roadmap and connections | 15 | 10 |
| AI capture and speech | 12 | 5 |
| Encrypted .rdm and key recovery | 13 | 2 |
| E2EE collaboration | 10 | 0 |
| Installer, updater and migrations | 5 | 0 |
| Mac integration, security review and release evidence | 5 | 1 |
| **Total** | **100** | **46** |

## Completed in this increment (13 — workspace layout stabilisation, no score change)

Written in response to the owner's manual Mac UI smoke test of the native target. **Source only and unverified: this workspace has no Swift toolchain and no macOS SDK, so none of it is compiled or run, and no point is credited for it.**

- `Sources/FolioCore/WorkspaceLayoutPolicy.swift`: window and pane geometry as pure domain code. The window minimum is 1040 × 640, enforced through `.contentMinSize` rather than assumed. Panes narrow toward a minimum (sidebar 240→200, capture panel 250→220) and are never hidden by a width threshold; the editor keeps at least 420 points, and 601 while Split is chosen (605 is reserved, so column rounding cannot flip the decision), so an explicit Split request narrows the panes instead of being refused. `EditorPaneLayout` reflows Split to a single Source pane with a stated reason if two usable panes ever cannot fit. The previous `PaneVisibility.writingFirst` thresholds are left untouched for their existing tests; the workspace no longer uses them, because hiding a pane at a width threshold is what moved every control on screen.
- Pane visibility is now explicit user state (`showsExplorer` / `showsAssistant`) exposed in a new **Workspace** menu and in the toolbar's overflow-safe "More" menu, so a hidden panel can always be brought back instead of being silently gone. No shortcut was attached: `ShortcutPolicy` owns the chord table and already uses ⌥⌘1/⌥⌘2/⌥⌘3 for Source/Preview/Split, so a menu item here can never shadow a remapped command.
- Shared workspace shell: pane widths from the policy, `minWidth: 0` plus `.clipped()` on every pane and on the section stack so a wide child cannot inflate its parent and push a sibling outside the window, `lineLimit(1)` on chrome labels with `fixedSize()` on controls so text truncates instead of wrapping character by character, and the toolbar reduced from ten items (which AppKit hid behind an overflow chevron) to Launcher + section picker + Open Note / New Note / More.
- Editor: `EditorPanes` now takes its widths from `EditorPaneLayout`; the Source editor stays mounted in every mode. Roadmap and Connections: single-line headers, flexible inspectors (240–300) instead of fixed 265/270, and `contentShape` on the timeline bars, Kanban cards and selection rows so a click lands on the whole control rather than its glyph.
- 16 new tests in `Tests/FolioCoreTests/WorkspaceLayoutPolicyTests.swift` pin the arithmetic and the invariants: pane minimums, editor-width monotonicity across a 120–2600 point sweep, the Split boundary at 601, and the reflow case. Increment 12's benchmark harness and its 9 tests are unchanged.

## Previous increment (12 — large-file/long-line benchmark harness, N02)

- `BenchmarkCorpora`/`BenchmarkStatistics` (`Sources/FolioCore/Markdown/MarkdownBenchmarks.swift`) and `FolioBenchmarkProbe`: the N02 benchmark item and decision 26's release-gate prerequisite. Deterministic named corpora sized against `MarkdownLimits` (small note, 256 KB and near-budget mixed notes, over-budget limitation path, 30K-character lines, ~10K blocks, mixed-construct stress) feed measured full parses, per-keystroke incremental reparses (splice-only figure included), link scans and excerpts — median/p95/min, table or JSON, **timings printed and never asserted** (decision 50 gives the gate no waiver path).
- `scripts/run-benchmarks.sh` records `Evidence/benchmarks.json` for crediting the `inputAndLargeDocumentCorrectness` gate on the machine class that will sign the release.
- 9 focused tests (421 total in source): corpus determinism, exactly one edit marker per corpus, budget targeting, parse outcomes including the limitation path, incremental-vs-full parse equality on every corpus, link-scan span round-trips, and the statistics definitions.

## Evidence status

- Mac compile evidence (Swift 6.3.2 / macOS 26 / arm64) confirms the vendored libarchive headers fix: `FolioArchive.c` now compiles. The run then exposed and fixed two unrelated portability defects: a malformed raw-HTML parser declaration and Apple SQLite’s unavailable load-extension API. No tests have executed on that host yet; rerun `bash scripts/test-core.sh` after the follow-up fix.
- The full Debug/Release core run recorded at Increment 07 remains the last complete execution evidence (333 tests, 0 failures).
- Increment 12's source and tests pass full swift-syntax parsing (118 Swift files, 0 syntax failures); its 9 tests (421 total in source) must run with `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. Unrun checks are blocking, not a pass.
- Increment 13 is **not compiled and not run anywhere**. No Swift toolchain and no macOS SDK are reachable from the workspace in which it was written (`download.swift.org`, `swift.org` and the Debian mirrors are unreachable; only PyPI and github.com respond), so the new policy file, its 16 tests and every view edit are unverified source. The only checks performed were (a) an independent Python mirror of `WorkspaceLayout.resolve` and `EditorPaneLayout.resolve`, run three times, which re-derived and matched every arithmetic expectation asserted in those tests — exact pane widths and shrink order, both monotonicity sweeps, the pane minimums and the Split boundary at 601 — and (b) a review of the diff. A mirror of the arithmetic is not a compile, not a test run and not evidence about SwiftUI behaviour. Every item on the owner's responsiveness checklist remains unchecked until the Mac run.
- The Increment 10 reparse algorithm additionally has 32,000 randomized edit-sequence equivalence checks (incremental vs full parse) from a development-time Python mirror of the same algorithm — strong design evidence, not a substitute for the Swift test run, and the harness is not shipped in the repository.
- No Mac SDK, CryptoKit/APFS, Keychain, accessibility, power-loss or independent security evidence exists here.

## Not established

- No Mac CryptoKit/APFS parity, fault/power-loss matrix, migrations or independent crypto review.
- No Keychain/device slot/recovery rotation, collaboration, installer or updater.
- No Mac SDK runtime/security/accessibility/performance signoff.
- Consistent rollback of both working slots to an older complete pair is not locally detectable (documented in the contract); the archive checkpoint remains the durable trust anchor.

No owner testing is requested until the approved feature set and mandatory gates are complete.
