# Folio — project handover snapshot

> **Status of this document.** This was the top-level `README.md` of the working
> workspace at **increment 07**, before the repository was reorganised into the
> current layout. Paths have been updated to the new structure. For the live map
> of the repository, use the root `README.md`.

**Development increment: 07 · Estimated completion: 41% · User testing: deferred · Release: blocked**

## Active work

- `App/` — the SwiftUI/AppKit/Metal macOS application source.
- `Sources/` and `Tests/` — the tested Swift/C core (`FolioCore`, `FolioFileIO`,
  `FolioRDMPrimitives`, `CArgon2`, `CSQLite`) and the storage, reading,
  planning, capture and speech probes.
- `docs/progress/PROGRESS.md` / `docs/progress/progress.json` — weighted
  estimate, evidence and reporting policy.
- `docs/planning/Folio-Feature-Completion.md` — the approved scope, remaining
  features and handoff gates.
- `docs/planning/Folio-Implementation-Plan.md` — implementation order and
  engineering acceptance criteria.
- `docs/planning/decisions/` — all 50 personal answers and the current
  implementation tracker.
- `assets/folio-app-icon.png` — your approved logo, unchanged.
- `tools/package-native.py` — current verification/packaging tool.

## Useful references retained

- `docs/reference/Folio-Baseline.md` / `docs/reference/Folio-Baseline.pdf` —
  original comprehensive baseline. Later personal decisions override conflicting
  defaults.
- `docs/reference/Folio-Roadmap.xlsx` — original proposed planning workbook, not
  a live implementation status.
- `docs/design/Folio-Prototype.html` and `docs/design/concepts/` — original
  browser design reference and captures, not execution evidence for the native
  app.

Duplicate exports, old incremental ZIPs, obsolete prototype/build tooling and
scratch output were removed under your cleanup request. `cleanup.json` (beside
this file) records the removal scope. The latest source, decisions, evidence and
approved identity were preserved.

Packaging writes a development source archive to `dist/`. It is development
source, not a release or a request for owner testing. No native Mac app or
installer has been built here.
