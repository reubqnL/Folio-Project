# Folio — completion estimate and evidence

**Estimated completion: 45% · Release readiness: blocked · Owner testing: HOLD**

Subjective weighted planning estimate; not verified security/correctness, percentage of code, or a release certificate.

| Area | Scope weight | Credited points |
|---|---:|---:|
| Product/design/decisions | 5 | 5 |
| Notes, project storage and search | 20 | 13 |
| Native editing, reading and accessibility | 15 | 9 |
| Roadmap and connections | 15 | 10 |
| AI capture and speech | 12 | 5 |
| Encrypted .rdm and key recovery | 13 | 2 |
| E2EE collaboration | 10 | 0 |
| Installer, updater and migrations | 5 | 0 |
| Mac integration, security review and release evidence | 5 | 1 |
| **Total** | **100** | **45** |

## Completed in this increment (11 — compact link repair, N02)

- `NoteLinkRepair` (`Sources/FolioCore/Markdown/NoteLinkRepair.swift`): broken and ambiguous note links are visible and repairable (baseline §4.2; decision 12). A span-preserving scanner finds every authored note link at an exact source location with exactly the inline parser's and knowledge graph's semantics — pinned by tests against both — and never counts links the graph would not treat as authored edges (code, literal HTML, metadata, rules, images, external/blocked/anchor targets, escapes).
- A repair rewrites exactly one confirmed link's target and nothing else: labels and `|alias` text survive, `#section` anchors are preserved, and the authored form is kept (title links stay titles, path links stay paths). Every edit is bound to the source digest it was computed against (stale application refuses) and is rejected if the replacement would not re-parse as a note link at the same site — embedded `]]`, `|`, `)` and similar can never corrupt the note.
- The compact repair sheet (decision 12: folder path, tags, modification date per candidate) lists the open note's missing and ambiguous links; healthy links are counted, not listed. Each replacement is one explicit confirmation; refusals state the reason and leave the note untouched. Reachable as "Repair Note Links…" in the toolbar and command palette (⌘⇧E, remappable under the existing safe-remapping policy).
- 24 new tests (412 total in source): scanner equivalence against `MarkdownInlineParser` and `GraphLinkExtractor` over an adversarial corpus, block-kind and table-cell policy, CRLF/emoji span round-trips, missing/unique/ambiguous resolution, form-preserving replacement text, single-occurrence rewrites with labels preserved, stale/span/blocked refusals, repairs through headings, quotes, list items and table cells, and the command's reachability/note scoping.

## Evidence status

- The full Debug/Release core run recorded at Increment 07 remains the last complete execution evidence (333 tests, 0 failures).
- This increment's source and tests pass full swift-syntax parsing (115 Swift files, 0 syntax failures); the 24 new tests (412 total in source) must run with `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. Unrun checks are blocking, not a pass.
- The Increment 10 reparse algorithm additionally has 32,000 randomized edit-sequence equivalence checks (incremental vs full parse) from a development-time Python mirror of the same algorithm — strong design evidence, not a substitute for the Swift test run, and the harness is not shipped in the repository.
- No Mac SDK, CryptoKit/APFS, Keychain, accessibility, power-loss or independent security evidence exists here.

## Not established

- No Mac CryptoKit/APFS parity, fault/power-loss matrix, migrations or independent crypto review.
- No Keychain/device slot/recovery rotation, collaboration, installer or updater.
- No Mac SDK runtime/security/accessibility/performance signoff.
- Consistent rollback of both working slots to an older complete pair is not locally detectable (documented in the contract); the archive checkpoint remains the durable trust anchor.

No owner testing is requested until the approved feature set and mandatory gates are complete.
