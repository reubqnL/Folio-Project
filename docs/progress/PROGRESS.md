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

## Increment 13j — why the build failed, and the check that let it happen

**The delivered commit did not compile, and the compiler error was misleading.** `26e628b` added `App/Views/SectionSegmentedControl.swift` and the owner's build failed with `cannot find 'SectionSegmentedControl' in scope` at `NotesWorkspaceView.swift:63` — a complaint about a type defined in a file that is plainly present in the repository.

**The file was never in the build.** The `swift-frontend -c …` command line in the owner's transcript lists every other file under `App/` and does not list `SectionSegmentedControl.swift`, which means the generated Xcode project did not reference it, which means it was never compiled. The source was correct; the build never saw it.

**The cause is `scripts/run-app.sh`.** Regeneration of `Folio.xcodeproj` from `project.yml` was guarded by a timestamp comparison:

    [[ ! -d Folio.xcodeproj || project.yml -nt Folio.xcodeproj || App -nt Folio.xcodeproj || Sources -nt Folio.xcodeproj ]]

`App -nt Folio.xcodeproj` compares the modification time of the `App` directory *itself*. Creating `App/Views/SectionSegmentedControl.swift` updates the mtime of `App/Views`, not of `App`. On the owner's machine the generated project was already newer than `App`, so xcodegen was skipped, the new file was never added to the project, and the build failed on a file that existed. The hole is general: **a file can appear anywhere under a source directory without that directory's own mtime moving**, so any check of this shape misses it — adding a file two levels deep, deleting one, or renaming one all pass the test that was meant to catch them. `scripts/verify-on-mac.sh` was never affected because it regenerates unconditionally.

**The fix:** `run-app.sh` now regenerates `Folio.xcodeproj` from `project.yml` on every run whenever xcodegen is available. Generating unconditionally costs a fraction of a second; getting it wrong costs a confusing compiler error about code that visibly exists, so the guaranteed-correct option is the one taken. If xcodegen is absent the script still builds an existing project and says so.

A second guard was added for the other way a file can be silently dropped: after generation, the script confirms the project references every `.swift` and `.xcassets` file under `App/`, and fails with the file's name if it does not. Since regeneration has just run against the current tree, a miss there is a fault in `project.yml`'s `sources:` entry rather than a stale timestamp, and it is reported as such. Both branches of that check were exercised here against a fabricated project file: with one file omitted it names that file and fails; with everything referenced it passes quietly.

**What this does and does not explain.** It explains the build failure completely and it explains why the failure appeared only for the newest commit — an older commit's files were all present when the project was last generated. It does not confirm anything about the toolbar switcher: the fix in `26e628b` is still unverified source, and the diagnostic below has still never run.

**Not verified:** neither the app target nor the toolbar fix has been compiled here. There is no Swift toolchain in this environment, so the claim that this compiles is the owner's next `bash scripts/run-app.sh` and nothing else.

## Increment 13k — the switcher works, and two adjustments to it

**The reported defect is confirmed fixed on the owner's machine.** After `de93042`/`a5bfdb8`, `bash scripts/run-app.sh` built and launched, and the owner reports: all three segments switch the section, the `Navigate → Open Roadmap` menu path works, and the bar looks as it did before. That closes the item reported three times across this branch. It also settles the standing diagnostic in favour of the earlier reading — a fault in the toolbar host's click delivery, not in the section state — and the fix in `26e628b` is no longer unverified source now that the file actually reaches the compiler.

**Two adjustments were requested, both confined to the control's own host.** The owner asked that the three segments be equally spaced, and that hovering the bar with no project open show a cursor indicating it cannot be clicked.

- **Equal segments.** `segmentDistribution` is now `.fillEqually`. The control sizes itself to three times its widest label instead of to the sum of the three labels, so `Notes` is the same width as `Connections` rather than roughly half of it. This makes the bar wider than it was, by about the difference between one `Connections` label and the `Notes`/`Roadmap` pair. The owner's instruction was explicitly "not too much so its still slick", so the amount is worth watching on the next build: `.fillEqually` is the narrowest setting that makes the three equal, and there is no narrower one, but the whole control can be brought back down by shortening a label if it reads as chunky.
- **The disabled cursor.** `NSSegmentedControl` leaves the arrow cursor over itself when disabled, so an inert control is indistinguishable from a working one until you click it and nothing happens. `SectionSwitcherSegmentedControl` overrides `resetCursorRects()` to add `.operationNotAllowed` over its bounds while disabled, and invalidates the cursor rects when `isEnabled` changes so the change takes effect without the pointer having to leave and re-enter. The tooltip also now says "Open a project to switch sections" instead of naming the three sections, since while disabled the useful information is why.

Nothing else about the control changed, and the appearance the owner asked to preserve is untouched apart from the segment widths they asked to change.

**Not verified:** the two adjustments above are unverified source. Neither can be exercised here — the cursor behaviour in particular is a property of a running AppKit window — so both rest on the owner's next build.

## Increment 13l — segment widths, set rather than distributed

**The owner's report on 13k:** the cursor change works, all three segments still switch, and the spacing is still wrong — *"Connections is too close to the edge. there should all be the same size"*.

**`segmentDistribution = .fillEqually` does not do what the phrase "equal width" suggests.** It equalises the segments to the widest segment's *total* width, and that total already includes the stock control's own padding around `Connections`. The result is three segments of identical width in which `Connections` sits close to its edges while `Notes` and `Roadmap` float in space. Every segment measures the same and none of them looks like the same thing. It was the wrong lever.

**Now the widths are set outright.** `SectionSwitcherSegmentedControl.equalizeSegmentWidths(labelPadding:)` measures each label with the control's own font, takes the widest (`Connections`), and sets every segment to `widest + labelPadding × 2`, with `labelPadding` a single file-level constant at the top of the file. Three identical segments, the same padding either side of every label. It runs from `makeNSView` and again from `updateNSView`, and only writes widths that differ, so a steady state costs a comparison rather than a layout invalidation.

The cost is real and worth stating: equalising to `Connections` makes the bar wider, because `Connections` is by some margin the longest of the three words. Roughly, the bar goes from about 210pt with per-label sizing to about 275pt under `.fillEqually` and about 300pt with this padding. The padding constant is the one number that moves it, and it is at the top of the file for exactly that reason.

The toolbar has the room. At the 1040pt minimum window width the leading Launcher item and the three trailing actions leave well over 600pt for the principal region, so a 300pt control is not near the point where AppKit would start hiding items behind a chevron — which is the mechanism that caused the original click-delivery defect, so it is worth confirming rather than assuming.

**Not verified:** unverified source. Neither the widths nor the cursor behaviour can be exercised here.

## Increment 14 — encrypted drafts were stored but unreachable

**The defect.** An open encrypted project's unsaved drafts are held in an encrypted local working store that keeps up to 256 of them, and `RDMProjectSession.restoreWorkingState()` returns all of them. The UI restored exactly one — the newest — into its single editor slot and said *"N more unsaved draft(s) stay preserved in the encrypted working copy"* without offering any way to see, open or discard them.

The consequence was worse than a missing feature. `discardDraft(id:)` removes a draft from the store, and the only control that reached it was the editor's **Discard**, which acted on whatever was open. So the only route to an older preserved draft was to destroy the newer ones standing in front of it, one at a time. Three unsaved drafts meant three recoveries, each one paid for by deleting the draft above it. The store was doing exactly what it was designed to do; nothing in the interface could reach the older two.

This is the item the encrypted contract already listed as outstanding — *"multi-draft review UX validation remains"*.

**The core guarantee was already proven.** `EncryptedWorkingStoreTests` and `RDMProjectSessionTests` cover the mechanism this change relies on: `testDiscardingDraftsClearsWorkingCopiesWhenNoneRemain` stages two drafts, discards one by id, and asserts the other is exactly what remains; `testChainedGenerationsRemainCurrent` covers generation chaining. The change is therefore a matter of surfacing a tested guarantee, not of adding a new one, and no new core test is required to justify it.

**The change.** `EncryptedProjectController` keeps `preservedDrafts`, the full list from the working store, refreshed after every operation that alters it: unlock, each confirmed staging write, checkpoint, discard, and reviewed resolution. `EncryptedProjectView` renders a **Preserved drafts (N)** card listing every preserved draft, newest first, with its path, character count and last-written time.

- The draft currently in the editor is listed too, marked *In editor*, rather than filtered out. The list is then the complete set the working copy holds, so the count in its header always matches the rows beneath it — a list that claims to show the drafts and silently omits one is how this defect started.
- **Open** loads another draft into the editor. It is refused while the open draft holds text that is not yet confirmed in the working copy, with the reason shown, because until that write confirms the editor holds the only copy.
- **Discard** removes one draft from the working store, disabled while inconsistent copies await review, since the store refuses writes until then and a button that always fails is worse than one that explains itself.
- A stale or unreadable working state deliberately leaves the last known list in place instead of replacing it with an empty one. Showing nothing would imply the drafts are gone, which is the opposite of the truth when the real situation is that Folio cannot currently read them.
- The restored-draft notice and the discard notice now say where the remaining drafts are instead of only that they exist.

**A limitation deliberately left in place:** *New encrypted note* is still disabled while a draft is open. That is existing behaviour, and changing it would mean deciding what happens to unconfirmed editor text — a question this change does not need to answer. Drafts are now reachable, which was the defect; starting a second draft alongside the first is a separate decision.

**Not verified:** unverified source. The encrypted workspace cannot be compiled or exercised in this environment, and no encrypted project has been opened on real hardware. The evidence for the underlying mechanism is the existing SwiftPM test suite; the evidence for this interface layer is the owner's next build.

## Increment 14b — the saved-passphrase Keychain item could not behave as written

**The compiler evidence.** `293a0b6` built and launched on the owner's Mac. `EncryptedProjectView` and `EncryptedProjectController` are part of the app target, so the encrypted workspace now has its first compiler evidence — it typechecks. That is compile evidence only: no encrypted screen has been opened, with or without a `.rdm` file.

**The defect.** `EncryptedPassphraseKeychain` — the optional "remember this passphrase" convenience store — asked for a protection class that macOS could not have applied, and combined it with an attribute that contradicts it.

1. **`kSecAttrAccessible` does nothing on the file-based keychain.** Apple's `SecItem.h` states the attribute "is currently not supported for OS X keychain items" unless the query targets the data protection keychain. macOS has two keychain implementations and `SecItem` picks between them from the query. Without `kSecUseDataProtectionKeychain`, an add **succeeds**, the protection class is silently dropped, and a later read reports the attribute absent. So the code asked for `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and got an item with no protection class at all, while reading as though it had one — the worst of both, because the intent is invisible in the stored state.

2. **`kSecAttrSynchronizable` contradicts `ThisDeviceOnly`.** This is the concrete bug. Apple's header states that when the synchronizable attribute is set alongside `kSecAttrAccessible`, the accessibility value may only be one whose name does **not** end in "ThisDeviceOnly", because such a class cannot leave the device. The code passed `kSecAttrSynchronizable: false` *and* `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The documented answer to a contradictory `SecItem` dictionary is `errSecParam` (-50), which reaches the user as "The encrypted-project Keychain operation failed (status -50)."

3. **Protection-class attributes are add-only, and were being updated.** Apple's guidance is to set them when the item is added and never change them; passing `kSecAttrAccessible` to `SecItemUpdate` can fail the whole update with `errSecParam`. `save` passed it in the update dictionary, so saving a *replacement* passphrase — ticking "remember", then ticking it again with a different passphrase — could fail on a transition that should simply overwrite the value.

**The change.** `save`, `load` and `remove` now run the documented path first: `kSecUseDataProtectionKeychain: true`, which is the only macOS keychain that honours `kSecAttrAccessible`, with the synchronizable attribute **absent** rather than false — absence expresses the same intent without the contradiction, since items are unsynchronised unless that attribute is set. `SecItemUpdate` now carries only `kSecValueData`, with the protection class set once at add time.

**The fallback, and why it is there.** The data protection keychain needs the process to be signed with an identity that provides an access group, and Folio's development builds are ad-hoc signed with no team. If it refuses — `errSecMissingEntitlement` (-34018) or `errSecNotAvailable` (-25291) — the operation is retried against the file-based keychain, which never requires entitlements but cannot enforce the protection class. That means the change cannot be worse than what it replaces: the previous behaviour is preserved exactly when the stronger store is unreachable, and improved when it is not. `load` also falls through on a miss, not only on a refusal, so a passphrase saved by a build that could only reach the file-based store is still found. A refusal plus a miss returns no saved passphrase rather than an error, because "type your passphrase" is the right instruction and turning it into a Keychain failure message would be wrong.

**What is not established.** None of this has been executed. Two Apple DTS answers conflict on whether `kSecAttrSynchronizable: false` alone selects the data protection keychain, which is why this code sets `kSecUseDataProtectionKeychain` explicitly rather than relying on that attribute. Whether the data protection keychain is reachable from an ad-hoc signed sandboxed build cannot be determined here; the fallback exists precisely because it cannot. The stored item's protection class cannot be verified without a Mac.

## Increment 14c — creating an encrypted project was blocked by the sandbox

**Reported by the owner:** "The RDM doesnt let u create an encrypted project."

**The cause is the sandbox, and it stops the very first write.** Folio asked for a **file** — `NSSavePanel` for creation, `NSOpenPanel` with a `.rdm` filter for opening — and then tried to use the folder around it. An encrypted project is not one file on disk: `RDMFileStore` also creates a `.folio` folder beside the archive, takes an advisory lock, and keeps the atomic staging area and the encrypted working drafts there. Apple's App Sandbox extends a panel-selected file grant to **that file alone**. DTS states it directly: *"When the user selects a file in the open panel, the system extends your sandbox to allow access to just that file. That extension does not apply to the directory containing that file, so if you try to create a new file in that directory … that will be blocked by the sandbox."* The same applies to a save panel — it returns a security-scoped URL for the file name entered, not for the directory.

So `RDMFileStore.init` failed at `fs.directory(".folio")` or at the lock acquisition, before any cryptography ran. Creation could never have worked in a sandboxed build, and **opening was broken the same way** — opening also takes the lock and reads the working store — which is worth noting because the failure would have been reported as two unrelated symptoms. Nothing in the storage layer was wrong; the container was doing what it was designed to do, and the panel was asking for too little.

**The fix: ask for the folder.** Creation and opening both present an `NSOpenPanel` that chooses a directory (`canChooseFiles: false`, `canChooseDirectories: true`, `canCreateDirectories: true`). That is the grant that covers everything the format writes, and it is what Apple recommends for output that is more than one file. Specifically:

- **Creation** takes the folder plus the project name already present in the card, and writes `<folder>/<project name>.rdm`. The destination is rebuilt from the name at the moment Create is pressed, so renaming the project after choosing the folder renames the file rather than writing to the previously previewed name. `archiveFileName(for:)` turns the name into a safe single path component — separators and control characters replaced, leading dots stripped, length bounded, empty falls back to "Encrypted project" — and `plannedArchiveName` uses the same function, so the card's preview and what gets written cannot disagree. The card now names the folder and the file explicitly.
- **Opening** takes the folder and finds the `.rdm` inside it. One archive opens straight away. Several are offered as a list to choose from rather than guessed at, because a folder is a legitimate place to keep more than one. None produces a clear message saying so.
- The folder grant is **held** for the session as a security-scoped resource, because checkpoints and working-copy writes happen throughout it, and released with the rest of the plaintext state when the project is locked or closed.

The create card's subtitle, the idle explanation and the copy-flow message were updated to say "folder" rather than "destination", since all three previously described a file picker.

**Not verified:** unverified source, and this one is structural rather than cosmetic. It cannot be compiled or exercised here, no encrypted project has been created or opened on real hardware, and the sandbox behaviour it depends on is documented by Apple but not observed on this project's own build. The next build is the first time any of it runs.

## Increment 14d — the encrypted container works on real hardware, and four silent dead ends

**First runtime evidence the encrypted area has ever had.** The owner created an encrypted project in a throwaway folder on their Mac, got the one-time recovery code screen, stored it, and then locked the project and reopened it with the passphrase. Creation, the recovery-code path, locking and unlocking all work on macOS. This is the first time any of it has run on real hardware; until now the evidence was the SwiftPM suite plus unverified SwiftUI source, and no `.rdm` file had ever existed outside a test fixture.

It also confirms the sandbox diagnosis in 14c. Asking for the folder instead of the file is what made the first write succeed, which is only consistent with the panel having granted access to the file alone.

**Four dead ends in the encrypted workspace, all of the same shape: a control that does nothing and says nothing.** The owner's most persistent complaint across this branch has been exactly this — a control that looks live and produces no result — so the pattern is worth eliminating wherever it appears, not only where it was reported.

1. **The plain-to-encrypted copy could report success while doing nothing.** `chooseToCreate` returned silently when the controller was not idle, so with an encrypted project already open the copy prepared its payload, announced "Copy prepared", and then no picker appeared and no reason was given. It now reports why it cannot proceed, and the copy path in `WorkspaceSession` checks whether the picker actually opened and says so if it did not.
2. **Write encrypted checkpoint did nothing with an empty note path.** Clearing the path field and pressing the button returned at the guard. It now asks for a path.
3. **The same button did nothing when the note had left the project.** The guard against a missing note identity returned silently; it now says the note is no longer part of the project and what to do instead.
4. **The two saved-passphrase buttons** returned silently with no file selected. Both now say to choose a project first.

The remaining `guard … else { return }` statements in the controller were audited rather than changed. They are phase guards behind buttons that only render in the matching phase, buttons already disabled in the corresponding state, or edges inside a task. A guard behind a disabled control is defence in depth, not a dead end, and the distinction is what decided which ones were changed.

**Not verified:** the four changes above are unverified source. The creation and reopen result is the owner's runtime report and stands on its own.

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
