# Folio — completion estimate and evidence

**Estimated completion: 44% · Release readiness: blocked · Owner testing: HOLD**

Subjective weighted planning estimate; not verified security/correctness, percentage of code, or a release certificate.

| Area | Scope weight | Credited points |
|---|---:|---:|
| Product/design/decisions | 5 | 5 |
| Notes, project storage and search | 20 | 13 |
| Native editing, reading and accessibility | 15 | 8 |
| Roadmap and connections | 15 | 10 |
| AI capture and speech | 12 | 5 |
| Encrypted .rdm and key recovery | 13 | 2 |
| E2EE collaboration | 10 | 0 |
| Installer, updater and migrations | 5 | 0 |
| Mac integration, security review and release evidence | 5 | 1 |
| **Total** | **100** | **44** |

## Completed in this increment (10 — incremental Markdown reparse, N02)

- `MarkdownReparseSession` (`Sources/FolioCore/Markdown/MarkdownIncremental.swift`): the reading preview no longer re-parses the whole note per keystroke. A line-level diff localises the edit to a reparse window; blocks outside it are spliced with their identities intact (content+occurrence ids, exact spans, merged warnings), so untouched preview blocks keep stable `ForEach` identities and scroll anchors.
- The algorithm proves its splice before using it: a 2-line lookahead window floor (setext underlines and table alignment rows decide boundaries ahead), window-EOF boundary proofs (`rule`/`listItem` at EOF can pair with a suffix line; blank-extension for open paragraphs/quotes/HTML; fence-close scan for unclosed code), straddle growth so no old block tail is ever dropped, the front-matter scan treated an edit in the first 129 lines as document-wide, and mid-document windows can never form metadata blocks. Every unprovable case — limited parses, over-budget sources, full-document edits — falls back to `MarkdownParser.parse`, so the incremental result is always parse-equal, never approximately equal.
- The parser was restructured for the splice (`parseDetailed`/`project`/`splitLines` internals) without changing its public output: `parse` and `excerpt` are byte-identical to before, and the existing 23 parser tests cover them unchanged.
- 23 focused tests: adversarial splice swallows (fence/table/quote), unclosed fences to EOF, closing fences appearing later, setext partner changes across the splice, front matter added/removed/inserted/never-suffix-reused, the two-line lookahead hazard, edit-then-undo, duplicate-block renumbering, untouched-id stability, empty/CRLF/emoji sources, budget fallbacks, and a 4,000-block document where one edit reparses at most 6 blocks (timings printed, never asserted).
- The preview (`MarkdownPreviewView`) keeps one session per document and preview mode on the main actor, runs `reparse` on a detached task, and rebuilds the session when excerpt mode toggles or the document changes.

## Evidence status

- The full Debug/Release core run recorded at Increment 07 remains the last complete execution evidence (333 tests, 0 failures).
- This increment's source and tests pass full swift-syntax parsing (112 Swift files, 0 syntax failures); the 23 new tests (389 total in source) must run with `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. Unrun checks are blocking, not a pass.
- The reparse algorithm additionally has 32,000 randomized edit-sequence equivalence checks (incremental vs full parse) from a development-time Python mirror of the same algorithm — strong design evidence, not a substitute for the Swift test run, and the harness is not shipped in the repository.
- No Mac SDK, CryptoKit/APFS, Keychain, accessibility, power-loss or independent security evidence exists here.

## Not established

- No Mac CryptoKit/APFS parity, fault/power-loss matrix, migrations or independent crypto review.
- No Keychain/device slot/recovery rotation, collaboration, installer or updater.
- No Mac SDK runtime/security/accessibility/performance signoff.
- Consistent rollback of both working slots to an older complete pair is not locally detectable (documented in the contract); the archive checkpoint remains the durable trust anchor.

No owner testing is requested until the approved feature set and mandatory gates are complete.
