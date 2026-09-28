# Planning and connections — Increment 04

## One authored model, multiple views

The roadmap is stored as an owned, versioned `.folio/roadmap.json` sidecar. It contains task/milestone IDs, title/details, status, optional calendar dates, linked note IDs and typed finish-to-start dependency edges. Array order is the canonical local ordering used by Kanban. Timeline, Kanban, task inspection and graph projection use those same IDs—not independent demo datasets.

The sidecar is plaintext in a plain vault. Graph projections are derived and never rewrite note text. A missing linked note stays a visible unresolved reference; it is not replaced by a guessed file.

## Planning semantics

- Timeline is the default; Kanban is another projection.
- Missing dates appear in Unscheduled. A due-only/start-only item is a point marker with explicit wording, not a fabricated duration.
- Dates are Gregorian `YYYY-MM-DD` values. Day arithmetic/comparison is independent of time zones and daylight-saving transitions.
- A milestone is a single calendar day. Invalid date ranges require repair.
- Dependencies mean finish-to-start at day precision. Same-day handoff is allowed; no time-of-day or resource/capacity scheduling is invented.
- Cycle detection is iterative, avoiding recursive-stack failure on long chains.
- Visible Move/status, reorder and bulk date/delete controls do not require dragging. Linked notes are not deleted when tasks are removed.
- Guided repair retains the attempted proposal. It previews edge removal, date swapping, milestone collapse or a successor date shift; no repair commits by itself. Other tasks are not silently rescheduled.
- Session undo/redo writes fresh revisions. External content changes invalidate history even if an external tool improperly reuses a revision UUID.

The UI source holds edits against the document version they started from. Rebase is explicit and still requires review. This is not a collaborative CRDT or a general automatic planner.

## Persistence and recovery

The selected vault's existing `PlainVaultStore` actor and single-Folio-writer lock own roadmap I/O. There is no separate uncoordinated writer.

```text
.folio/roadmap.json
.folio/roadmap-journal/<UUID>/
  before.json          # absent for initial creation
  proposed.json
  install.json         # staged replacement; retains displaced bytes after exchange
  intent.json          # sealed after payload writes
  committed.json       # after install and barriers
  REVIEW               # if explicit intervention is required
  external.json        # optional preserved conflicting bytes
```

- Creation is non-clobbering; replacement uses the same descriptor-relative, metadata-preserving atomic-exchange mechanism as notes.
- Expected base bytes and project/root session identity are checked. A stale base or raced exchange retains the proposal/displaced version and does not issue a successful save result.
- Valid sealed transactions can recover only against their expected base or already-installed proposal. Committed records never roll back later external work.
- Copied-workspace handling honours the existing restore/fork choice. Review-only/cross-identity records never auto-replay.
- Unknown schema/fields, corrupt payloads and unsafe paths are refused rather than silently migrated or erased.
- Current bounds are 10,000 tasks, 50,000 dependency edges, 8 MiB encoded roadmap and 128 MiB roadmap-journal quota. Roughly eight committed snapshots plus the current write are retained; unresolved records are not silently pruned.

These bounds and the Linux process tests are not proof of APFS power-loss durability. Complete conflict/recovery-management UX, migration policy and native filesystem validation remain required.

## Graph semantics

The catalog combines:

1. authored Markdown note-to-note links, excluding code, raw HTML, metadata and image placeholders;
2. explicit roadmap-to-note links;
3. roadmap dependencies.

Ambiguous/missing textual link targets are counted, not guessed. Deleted note IDs linked by tasks remain visibly missing. Link extraction currently shares the bounded Markdown subset; over-budget/unreadable bodies are disclosed. The Mac source caps a scan at 512 KiB per body and 64 MiB of body text per graph build, with metadata still represented. This is a development bound, not complete large-vault indexing.

- Default spatial view is 2D; 3D exploration is explicit opt-in.
- One-hop neighbourhood is the default; two hops are requested explicitly.
- A click inspects. Open, Enter or double-click navigates deliberately. Merely selecting a graph node does not replace the editor's document.
- Graph/list switching keeps selection; the list exposes the logical neighbourhood, not just individually rendered nodes.
- Dense groups become labelled clusters with counts. Expansion is a rendering projection and never merges/deletes canonical entities.
- Hardware/power/thermal-aware caps bound rendered nodes/edges. Counts disclose aggregation and omissions.
- Deterministic bounded CPU layout runs off the UI actor. Camera math, hit testing, layout and projections are core-tested.

## Native Metal source

The Mac source uses `MTKView`, Metal triangles/lines and reusable in-flight vertex buffers. It is paused with invalidation-driven drawing; there is no continuously running idle simulation. CPU projection supports pan/zoom and opt-in orbit/perspective. The equivalent list remains available if Metal setup fails.

This renderer and its inline Metal shader **have not executed on a Mac GPU here**. Linux Swift parsing does not typecheck MetalKit/AppKit APIs, compile MSL, verify buffer layout on the Mac, prove accessibility, or establish frame-time/energy budgets. All those gates remain open.

## Evidence

The core suite includes date precision, moves/reordering, dependencies/repairs, undo/stale histories, persistent roadmap data, interrupted transactions, graph identity/links/clustering/layout and camera bounds. A generated-vault scenario exercises the shared planning/graph/store model; a separate runner sends real SIGKILL at create/update transaction boundaries.

Feature development continues. The owner has requested a feature-complete Mac handoff before their own testing; this increment is not that handoff and does not waive any release/security gate.
