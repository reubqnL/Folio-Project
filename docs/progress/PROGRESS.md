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

## Completed in this increment (12 — large-file/long-line benchmark harness, N02)

- `BenchmarkCorpora`/`BenchmarkStatistics` (`Sources/FolioCore/Markdown/MarkdownBenchmarks.swift`) and `FolioBenchmarkProbe`: the N02 benchmark item and decision 26's release-gate prerequisite. Deterministic named corpora sized against `MarkdownLimits` (small note, 256 KB and near-budget mixed notes, over-budget limitation path, 30K-character lines, ~10K blocks, mixed-construct stress) feed measured full parses, per-keystroke incremental reparses (splice-only figure included), link scans and excerpts — median/p95/min, table or JSON, **timings printed and never asserted** (decision 50 gives the gate no waiver path).
- `scripts/run-benchmarks.sh` records `Evidence/benchmarks.json` for crediting the `inputAndLargeDocumentCorrectness` gate on the machine class that will sign the release.
- 9 focused tests (421 total in source): corpus determinism, exactly one edit marker per corpus, budget targeting, parse outcomes including the limitation path, incremental-vs-full parse equality on every corpus, link-scan span round-trips, and the statistics definitions.

## Evidence status

- First Mac build attempt (Swift 6.3.2 / macOS 26 / Xcode 26) reached compilation and failed only on missing libarchive headers (macOS ships the compiled system library without headers). Fixed by vendoring a declaration-verbatim subset of the libarchive 3.7.7 headers (`Sources/FolioRDMPrimitives/vendor/libarchive/`) and linking the system library — zero extra installs on the Mac. No tests have executed on that host yet; `bash scripts/test-core.sh` is the next step there.
- The full Debug/Release core run recorded at Increment 07 remains the last complete execution evidence (333 tests, 0 failures).
- This increment's source and tests pass full swift-syntax parsing (118 Swift files, 0 syntax failures); the 9 new tests (421 total in source) must run with `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. Unrun checks are blocking, not a pass.
- The Increment 10 reparse algorithm additionally has 32,000 randomized edit-sequence equivalence checks (incremental vs full parse) from a development-time Python mirror of the same algorithm — strong design evidence, not a substitute for the Swift test run, and the harness is not shipped in the repository.
- No Mac SDK, CryptoKit/APFS, Keychain, accessibility, power-loss or independent security evidence exists here.

## Not established

- No Mac CryptoKit/APFS parity, fault/power-loss matrix, migrations or independent crypto review.
- No Keychain/device slot/recovery rotation, collaboration, installer or updater.
- No Mac SDK runtime/security/accessibility/performance signoff.
- Consistent rollback of both working slots to an older complete pair is not locally detectable (documented in the contract); the archive checkpoint remains the durable trust anchor.

No owner testing is requested until the approved feature set and mandatory gates are complete.
