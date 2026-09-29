# Folio documentation

Start at the repository root [`README.md`](../README.md) for the project
overview, repository map and build instructions.

## Index

### Development

| Document | Contents |
|---|---|
| [`native-development.md`](native-development.md) | Native build, verification commands, open Mac gates, privacy boundaries and the state of the encrypted container. This was the package `README.md` before the reorganisation. |
| [`CHANGELOG.md`](CHANGELOG.md) | Increment history, newest first (10 is current). |

### Architecture and security contracts

Each contract states the intended behaviour, what has been tested and what
remains unverified. They are the authoritative statements of what the code is
expected to guarantee.

| Document | Area |
|---|---|
| [`architecture/STORAGE-CONTRACT.md`](architecture/STORAGE-CONTRACT.md) | Plain-Markdown vault, journaling, crash recovery, durability acknowledgement (N01), reconciliation |
| [`architecture/READING-SEARCH-CONTRACT.md`](architecture/READING-SEARCH-CONTRACT.md) | Local search index and reading workflow |
| [`architecture/PLANNING-GRAPH-CONTRACT.md`](architecture/PLANNING-GRAPH-CONTRACT.md) | Roadmap, timeline projection and knowledge graph |
| [`architecture/CAPTURE-SECURITY-CONTRACT.md`](architecture/CAPTURE-SECURITY-CONTRACT.md) | Model capture: explicit context, review before apply, stale-edit protection |
| [`architecture/SPEECH-SECURITY-CONTRACT.md`](architecture/SPEECH-SECURITY-CONTRACT.md) | On-device voice capture consent, lifecycle and handoff |
| [`architecture/RDM-SECURITY-CONTRACT.md`](architecture/RDM-SECURITY-CONTRACT.md) | Threat model for the encrypted container |
| [`architecture/ENCRYPTED-RDM-CONTRACT.md`](architecture/ENCRYPTED-RDM-CONTRACT.md) | Encrypted `.rdm` format, KDF, archive, checkpoint, working store and index cache |

### Planning and decisions

| Document | Contents |
|---|---|
| [`planning/Folio-Implementation-Plan.md`](planning/Folio-Implementation-Plan.md) | Implementation order and engineering acceptance criteria |
| [`planning/Folio-Feature-Completion.md`](planning/Folio-Feature-Completion.md) | Approved scope, remaining features and handoff gates |
| [`planning/decisions/User-Decisions.md`](planning/decisions/User-Decisions.md) | All 50 recorded product/engineering answers, human-readable |
| [`planning/decisions/answers.json`](planning/decisions/answers.json) | The same answers in machine-readable form |
| [`planning/decisions/Implementation-Tracker.md`](planning/decisions/Implementation-Tracker.md) | Per-decision implementation status |

The recorded decisions are the product authority: they override conflicting
defaults in the original baseline.

### Progress and estimates

| Document | Contents |
|---|---|
| [`progress/PROGRESS.md`](progress/PROGRESS.md) | Weighted completion estimate, evidence and reporting policy |
| [`progress/progress.json`](progress/progress.json) | The same estimate in machine-readable form |

### Reference and design

Historical material retained for context. None of it describes the current
implementation, and none of it is evidence that a native feature works.

| Document | Contents |
|---|---|
| [`reference/Folio-Baseline.md`](reference/Folio-Baseline.md) | Original comprehensive baseline (Markdown) |
| [`reference/Folio-Baseline.pdf`](reference/Folio-Baseline.pdf) | Original comprehensive baseline (PDF) |
| [`reference/Folio-Roadmap.xlsx`](reference/Folio-Roadmap.xlsx) | Original proposed planning workbook |
| [`reference/project-handover.md`](reference/project-handover.md) | Workspace handover snapshot from increment 07 |
| [`reference/cleanup.json`](reference/cleanup.json) | Record of files removed during the earlier workspace cleanup |
| [`design/Folio-Prototype.html`](design/Folio-Prototype.html) | Browser design prototype |
| [`design/concepts/`](design/concepts/) | UI concept captures (launcher, notes, graph, roadmap, timeline, installer, privacy) |

### Third-party notices

| Document | Contents |
|---|---|
| [`notices/Argon2-LICENSE.txt`](notices/Argon2-LICENSE.txt) | Licence for the vendored Argon2 reference source |
| [`notices/Argon2-provenance.json`](notices/Argon2-provenance.json) | Upstream commit provenance for the pinned Argon2 source |
| [`notices/Apple-Speech-Sample-License.txt`](notices/Apple-Speech-Sample-License.txt) | Apple sample attribution referenced by the speech integration |

## Generated evidence

`Evidence/` (at the repository root) holds generated test reports and logs. It
is deliberately not committed; see [`../Evidence/README.md`](../Evidence/README.md).
