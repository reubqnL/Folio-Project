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

## Owner's Mac attempt on Increment 13 (2026-09-29) — the increment did not run

**Both Mac test runs executed commit `9ea22ce`, not the layout branch.** The transcript shows `git checkout arena/01a0eec2-folio-project` aborting ("Your local changes to the following files would be overwritten by checkout: App/Speech/AppleSpeechPipeline.swift, App/WorkspaceSession.swift"), and both subsequent runs reporting **421 tests** — the base-commit count. The layout branch has 437. Therefore:

- The 16 `WorkspaceLayoutPolicy` tests have still never executed anywhere.
- Not one line of the layout work was compiled or launched, so **every item on the responsiveness checklist remains unchecked** and the defects in the owner's report are still unreproduced, unfixed and untested in a running app.
- The three compatibility edits the owner had made locally are already contained in the same commit, so the branch can be checked out once those two files are resolved (the stash/verify sequence is in the handover note).

Two environment defects were found and fixed from that transcript:

1. **`swift run` cannot launch the app.** It reports "multiple executable products available: folio-storage-probe, …". The package defines six probes; the app is the Xcode target in `project.yml`. Added `scripts/run-app.sh` (generate → build → launch) and documented why in the README and `docs/native-development.md`.
2. **Building inside the owner's cloud-synced checkout fails at signing.** `verify-on-mac.sh` failed with `resource fork, Finder information, or similar detritus not allowed` while signing `FolioCoreTests.xctest`. The checkout lives under `~/Library/CloudStorage/OneDrive-Personal/…`, whose file provider attaches `com.apple.FinderInfo`/`com.apple.ResourceFork` attributes that `codesign` rejects. The transcript proves the mechanism: the earlier `scripts/test-core.sh` run, whose scratch path defaults to `$HOME/.cache/folio-core-build`, signed and passed; the same tests with their scratch path under the repository's `.build-output` did not. `verify-on-mac.sh` and the new `run-app.sh` now default to `FOLIO_BUILD_DIR=$HOME/.cache/folio-mac-build`, clear attributes defensively before signing, and warn when the checkout is inside a synced folder. The probe scripts' `--temp-parent` defaults, which also pointed into the synced tree, are now given explicit non-synced paths by the script.

### Follow-up on the same day: the branch run succeeded

The stash/checkout sequence then landed on `188314e`, and `bash scripts/test-core.sh` produced a complete run on macOS 27.0.1 / arm64 / Swift 6.4:

- **437 Debug and 437 Release tests, 0 failures** — the branch's own count, on the branch's own commit.
- All six probes PASS (storage, reading, planning, capture, speech, benchmark), the 13 storage and 12 roadmap SIGKILL scenarios PASS, and the ASan/UBSan audio ring PASS with 100,000 synthetic frames.
- This is the first execution of Increment 13's 16 `WorkspaceLayoutPolicyTests` anywhere. All 16 passed, including `testChoosingSplitNarrowsThePanesInsteadOfBeingRefused` (the `isCompact == false` assertion previously flagged as the most likely failure) and the narrowest-Split bound at 1027 points.
- Nothing was written into the OneDrive checkout: the run used the scripts' `$HOME/.cache/...` defaults, which is why it signed and passed where the earlier `verify-on-mac.sh` attempt against `.build-output` did not.

One local file is not a defect: `App/Info.plist` shows as modified on the owner's Mac because that file is **generated by XcodeGen** — `project.yml` declares `info.path` together with `info.properties`, so every `xcodegen generate` rewrites it. It is an output, not a source of truth, and the edit does not affect the app.

## First successful app run and the owner's first report (2026-09-29)

`bash scripts/run-app.sh` built and launched the Folio app target — the first compile of any `App/` source and of the window configuration added in Increment 13. The owner's report from that run:

- **Resizing works and elements no longer disappear.** The reported defect that dominated the original report is not reproduced by this build.
- **Section switching works**: the toolbar segmented control and the sidebar items both move between Notes, Roadmap and Connections, the highlight follows, and the header survives switching and typing. This retracts the earlier "menu does nothing" observation — that was the button's own click animation, not a failed switch.
- **Note body text lays out correctly.** The remaining wrap complaint is `character-by-character vertical text`, in the owner's words `all of it is awful` and present `at any window size`.

Three defects were confirmed from the transcript and fixed in `2b4eee6`:

1. **The capture panel reported a cancellation that never happened.** `CaptureController.clear()` called `cancel()` unconditionally, and `cancel()` sets the status to "Cancellation requested. Late output will not be applied." The session calls `capture.clear()` on the success path of opening a project, so opening any project made the panel claim a cancellation for a capture that was never started. `clear()` now keeps that status only when a request was genuinely in flight (`activeRequestID != nil || isGenerating`) and otherwise restores the idle message, which is now the named constant `CaptureController.idleStatus`.
2. **Two chrome labels could wrap one character per line.** The roadmap timeline's window-start date — squeezed between two arrow buttons, a Picker and a Spacer — and the connections canvas legend now carry `lineLimit(1)` with `fixedSize()`/truncation and a `.help` string carrying the full text.
3. **"Follow cursor" read like a toggle that never showed its state.** It is a one-shot action (it scrolls the preview to the cursor once and is not a mode, which decision 05 requires and `CommandTests` pins as "never implies auto-scroll"). It is now labelled "Jump to Cursor" in both the preview header and the command title, and it shows a brief "Jumped" confirmation so a click that changes nothing visible still reports that it ran.

Also added: **File → Open Recent**. `WorkspaceSession.recordProject` had been writing the last 50 projects to `knownProjectIdentities` since an earlier increment, but nothing ever read them back, so the feature existed only as dead storage. The folder is remembered as a **security-scoped bookmark** (`KnownProjectIdentity.bookmark`), not a path, because this build is sandboxed and a remembered path carries no permission to reopen; `folderPath` is display-only. `openRecentProject` reuses the same body as the open panel via a new `openProject(at:grant:mayCreate:)`, with `mayCreate: false` so Open Recent can never offer to initialise a project in a folder the user did not just choose, and a folder that can no longer be resolved is reported and dropped from the menu rather than opened somewhere else.

### The vertical text: root cause found (2026-09-29)

The owner's screenshot showed a tall column of letters spelling **"Editor presentation"** immediately left of the Source/Preview/Split control. That identified the defect precisely, and it was not the narrow-window text wrapping the previous round had been chasing — which is why that round's `lineLimit(1)` additions never touched it.

**A SwiftUI `Picker` draws its own label next to the control.** A segmented picker shows the title string beside the segments, and a menu picker shows it beside the popup button. Those labels are ordinary `Text`, so when the surrounding row is tighter than the sum of its fixed-width children, the label is the child that gets compressed — down to a few points — and SwiftUI wraps it at whatever character fits. The result is one or two letters per line: the reported vertical text.

Five pickers sat in exactly that position and had no `labelsHidden()`:

| Where | Picker | Label that wrapped |
|---|---|---|
| Notes editor header | `EditorPresentation` | "Editor presentation" |
| Notes toolbar | `WorkspaceSection` | "Workspace section" |
| Roadmap header | `RoadmapPresentation` | "Roadmap view" |
| Roadmap timeline | window length | "Window" |
| Connections header | neighbourhood depth | "Neighbourhood depth" |
| Capture panel | `CaptureSourceKind` | "Input kind" |

All six now carry `.labelsHidden()`, which removes the label from layout while keeping it as the control's accessibility title, and the self-describing chrome pickers gained a `.help()` string restating it. The pattern is the project's own precedent: the base commit already used `.labelsHidden()` on the roadmap's "Add prerequisite" picker — it had simply been missed everywhere the label was under pressure. The pickers whose labels are informative and have room (search scope, task editor, settings forms, capture review) keep their visible labels.

**Confirmed fixed (2026-09-29).** The owner rebuilt at `9f5096f` and reported: *"seems to be working just fine. nav works, those vertical text things are hidden."* No vertical text remains, and section navigation works from both the toolbar and the sidebar.

**What that closes:** the layout work has now been built and run, and the two reported defects that this increment set out to fix — controls disappearing on resize, and character-by-character vertical text — are both absent in a running app. The owner's responsiveness checklist can now be marked for those items.

**What it does not close:** the checklist's remaining items are unchecked. The capture panel's phantom cancellation and File → Open Recent were changed in the same unrebuilt commits and have not yet been exercised, and Source/Preview/Split in a normal window, resize-to-floor control hit-testing, and the note-editing regression set (create, edit, save, reopen, search) have not been re-walked since `188314e`.

**Later the same day, all three were confirmed working** on the next rebuild: the capture panel no longer reports a phantom cancellation, `File → Open Recent` reopens the project, and the relabelled **Jump to Cursor** control behaves as a one-shot action. The owner's summary of the whole screen was *"I think it works perfectly fine for the moment."* That leaves the regression set (create, edit, save, reopen, search) and the resize-to-floor hit-testing walk as the only unchecked items from the original report.

## Polish pass on the existing screens (2026-09-29)

Owner's direction: improve what is already there before adding anything, and prioritise the encrypted `.rdm` work next. Three defects were found by reading the Notes, Roadmap and Connections sources:

1. **The toolbar's note picker and the left sidebar shared one filter string.** Both `TextField`s were labelled "Filter filenames" and both bound to a single `@State private var filter`, so typing in the toolbar popover silently narrowed the sidebar list too, and closing the popover left the project list filtered by text that was no longer visible anywhere. The picker now owns `pickerFilter`, filters through its own `pickerNotes`, states when nothing matches, and clears itself on dismiss.
2. **Six icon-only buttons in `RoadmapView` had no accessibility label** — undo, redo, both timeline date arrows, the card's edit pencil, and the prerequisite remove button. They had `.help()` tooltips, which is not the same thing. `ConnectionsView` already paired `.help()` with `.accessibilityLabel()` on every icon button, so this was a gap against the project's own standard; all six now match.
3. **"Recovery…" in the toolbar's More menu was enabled with no project open**, where it silently did nothing because `recoverProject()` returns early without a store. Every neighbouring item was already disabled in that state; it now is too.

**Not verified:** unverified source. Nothing in this pass has been compiled or run.

### Second polish pass: screens that answered a question with silence (2026-09-29)

The first pass fixed one shared-state bug and some missing labels. Reading the rest of the surfaces for the same class of defect — a control that accepts input and then says nothing about what happened to it — turned up six more:

1. **`GraphController.configure` never reset `listFilter`.** The Connections list filter survived a project switch, so opening a second project after filtering in the first left the list silently narrowed by a term with no visible cause. It now resets with the rest of the per-project state.
2. **The Connections list had no empty state.** A filter matching nothing and a project with no links at all rendered identically: an empty list. It now distinguishes them, states the count it is filtering from, and offers a Clear Filter button.
3. **A failed timeline projection rendered nothing.** `if let projection = try? TimelineProjection(…)` had no `else`, so any window that could not be projected produced a blank timeline area. It now explains the state and offers a one-click reset to Today with a 6-week window; the code path is reachable when the window has been scrolled far enough for the calendar arithmetic to fail.
4. **Search reported no result count.** `NoteSearchController.message` describes index state only, so a query matching nothing showed an empty list under "Local search ready". The search sheet now says which scope was searched and that matching is literal.
5. **The command palette had no empty state**, so a query matching no command produced a blank list under the title.
6. **The sidebar and the kanban board both filtered silently.** The sidebar showed nothing when a filter matched no filename; the board's column headers counted every item in a status while the columns displayed only filtered ones, so a filter made the header contradict the column. The sidebar now names the unmatched term with a Clear button; the board counts "shown of total" and offers Clear when nothing matches anywhere.

**Not verified:** unverified source, like the pass above.

## The section switcher: third report, and the owner's design decision (2026-09-29)

The toolbar's Notes/Roadmap/Connections control was reported for the third time as *"clicking but not doing anything"*, with the owner asking whether it *"randomly chooses when to work"*.

**A redesign was attempted and rejected.** `95b8294` replaced the segmented Picker with three plain `Button`s, mirroring the sidebar. The owner's response was to keep the existing look: *"Do NOT redesign it, keep it the same as previous iterations."* That commit was reverted in full, including its progress notes, and the control's appearance is unchanged from `9f5096f`.

**What the evidence actually says.** The fault is intermittent and window-width dependent, and it is a property of the picker's toolbar host rather than of the section state:

- A segmented `Picker` inside `ToolbarItem(placement: .principal)` is drawn by SwiftUI but sized by AppKit. When the item's bounds end up narrower than the control, every segment stays visible while only the part inside those bounds receives clicks. **Notes is leftmost and is usually the section already showing, so it appears to work while Roadmap and Connections do nothing** — which is exactly the reported asymmetry, and why it looks arbitrary.
- The state model is not implicated. `workspaceSection` is a plain stored property, `setWorkspaceSection` is unconditional, and the only disablement is `project == nil`. `refreshProject` — the one background path that runs while the owner is reading — never writes to it.
- A regression was introduced in `9f5096f` and removed here: `.fixedSize()` was added after `.frame(width: 300)`, and `.fixedSize()` discards that width in favour of the control's ideal size. That made the item-versus-control mismatch worse, though it was not the original cause — the base commit, which had a stiff `.frame(width: 275)` and no `fixedSize()`, failed the same way.

**The fix, with the appearance preserved:** `App/Views/SectionSegmentedControl.swift` hosts an actual `NSSegmentedControl` through `NSViewRepresentable`. On macOS this is the same control SwiftUI's segmented picker draws — same labels, same rounded style, same position in the toolbar — but as an `NSView` it reports a real intrinsic content size to AppKit and performs its own hit testing, so the item is sized to what is drawn. Its content-hugging and compression-resistance priorities are both `.required`, so it cannot be squeezed into a state where a segment is visible but unclickable.

The coordinator writes the selection only when it differs from the current section, so the binding's side effects (building the graph, loading the roadmap) run on real changes rather than on every click.

**Not verified:** unverified source. The diagnostic that will settle it either way: if **Navigate → Open Roadmap (⌥⌘R)** switches the section but the toolbar control still does not, the fault is in click delivery; if neither works, it is in the section state, which would contradict everything above.

## Evidence status

- Mac compile evidence (Swift 6.3.2 / macOS 26 / arm64) confirmed the vendored libarchive headers fix and exposed two unrelated portability defects (a malformed raw-HTML parser declaration and Apple SQLite's unavailable load-extension API). Both are fixed, and the owner's macOS 27 run below executed the suite that covers them.
- **The baseline commit `9ea22ce` has a complete macOS 27.0.1 / arm64 / Swift 6.4 run** of `scripts/test-core.sh`: 421 Debug and 421 Release tests with 0 failures, all six probes PASS, the 13 storage and 12 roadmap SIGKILL process scenarios PASS, and the ASan/UBSan audio-ring harness PASS. That run displaced the Increment 07 Linux run (333 tests) as the most recent complete execution evidence, and it does not cover the tests added in Increment 13.
- **The layout branch `188314e` now has the same complete run, on the same machine and toolchain**: 437 Debug and 437 Release tests with 0 failures, all six probes PASS, the same 13 + 12 SIGKILL process scenarios PASS, and the ASan/UBSan audio-ring harness PASS. Increment 12's 9 tests are counted in the 437; Increment 13's 16 are new to it.
- **What that run does not cover: the application target.** `scripts/test-core.sh` builds the SwiftPM package (`Sources/`, `Tests/`); the `App/` sources are compiled only by the Xcode target that `scripts/run-app.sh` builds, and that build had not been run when this paragraph was written. So the layout *policy* is now verified and none of its *use* is: `NotesWorkspaceView`, `EditorPanes`, `RoadmapView`, `ConnectionsView`, `LauncherView`, `CapturePanel` and the window configuration in `FolioApp.swift` have still never been through a compiler. Every item on the owner's responsiveness checklist stays unchecked until `run-app.sh` has run and the app has been probed by hand.

- Before that Swift run, the only checks performed on Increment 13 were (a) an independent Python mirror of `WorkspaceLayout.resolve` and `EditorPaneLayout.resolve`, run three times, which re-derived and matched every arithmetic expectation those tests assert — exact pane widths and shrink order, both monotonicity sweeps, the pane minimums and the Split boundary at 601 — and (b) a review of the diff plus `bash -n` on the two changed shell scripts. A mirror of the arithmetic was never a compile, a test run or evidence about SwiftUI behaviour; the executed tests above have now superseded the arithmetic half of it, and the SwiftUI half still stands.
- The Increment 10 reparse algorithm additionally has 32,000 randomized edit-sequence equivalence checks (incremental vs full parse) from a development-time Python mirror of the same algorithm — strong design evidence, not a substitute for the Swift test run, and the harness is not shipped in the repository.
- No Mac SDK, CryptoKit/APFS, Keychain, accessibility, power-loss or independent security evidence exists here.

## Not established

- No Mac CryptoKit/APFS parity, fault/power-loss matrix, migrations or independent crypto review.
- No Keychain/device slot/recovery rotation, collaboration, installer or updater.
- No Mac SDK runtime/security/accessibility/performance signoff.
- Consistent rollback of both working slots to an older complete pair is not locally detectable (documented in the contract); the archive checkpoint remains the durable trust anchor.

No owner testing is requested until the approved feature set and mandatory gates are complete.
