# Folio — personal decision log

The user's answers override conflicting defaults in the September 2026 baseline. Unanswered questions remain open; a recommendation is not an approval.

## Confirmed — questions 01–04

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 01 · Return journey | Always show the launcher | Start the app at the two-module launcher. FolioNotes is active on the left; FolioDev stays disabled on the right. Do not silently resume a workspace. |
| 02 · Workspace density | Give the editor more room | Collapse the AI inspector first as width decreases; collapse the file explorer only when necessary. Preserve editing space. Exact thresholds are engineering defaults, not separately approved values. |
| 03 · New-note flow | Ask for title and location | Show a creation sheet with both fields. Do not create an untitled file or Inbox note before confirmation. |
| 04 · Rich-text paste | Convert and notify | Convert supported formatting to Markdown without a blocking review dialog. Show a small notice with Undo and disclose unsupported formatting. |

## Confirmed — questions 05–08

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 05 · Editing modes | Keep my writing cursor fixed | Preserve the Markdown selection/cursor. The preview moves through an explicit Follow cursor control rather than forced synchronized scrolling. Detailed block mapping remains an implementation task. |
| 06 · Voice correction | Review the transcript first | Show an editable transcript and require confirmation before AI restructuring. Do not automatically retain raw audio. |
| 07 · AI review | “Let the user choose” | Offer whole-draft, section-level and detailed-comparison review. Do not impose one mandatory mode. A remembered default has not been specified. |
| 08 · AI context | Always-visible context list | Keep the included selection/notes beside the prompt, with Add/Remove controls. Never silently expand scope. |

## Confirmed — questions 09–12

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 09 · Stale AI result | Compare with the latest writing | Preserve current edits and show a comparison against the current revision. Never apply the stale suggestion over newer text automatically. This safety check applies regardless of the chosen review mode. |
| 10 · Finding and commands | Search and commands separately | One search interface for note titles and contents; a separate command palette. |
| 11 · Organisation | Project spaces first | Lead with a project's notes, roadmap and related entities. Preserve the underlying file locations; grouping alone must not silently move files. |
| 12 · Link resolution | Compact details | Show folder path, tags and modification date. Keep the original link until its replacement is confirmed. |

## Confirmed — questions 13–16

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 13 · Graph navigation | Start in a flat view | Default to 2D pan/zoom. Offer an explicit entry into 3D exploration; 3D remains a planned capability, not the default camera mode. |
| 14 · Graph scope | Only direct connections | Start with the focused note and its immediate neighbours. Expand to a wider neighbourhood only on request. |
| 15 · Non-spatial navigation | Switch graph ↔ list | Provide a button and shortcut to switch presentations while preserving the selected entity and navigation context. |
| 16 · Graph density | Collapse groups into clusters | Represent dense groups as labelled, expandable clusters with counts. Clustering is a view projection; it does not merge or delete the underlying notes. |

## Confirmed — questions 17–20

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 17 · Cross-view selection | Inspect first, open explicitly | A click selects and inspects without switching the working document. Enter, double-click or Open performs explicit navigation. |
| 18 · Roadmap entry | Timeline first | A new project roadmap opens in Timeline. Kanban remains an alternate projection of the same entities. |
| 19 · Undated work | Unscheduled tray beside the timeline | Keep undated work visible in an Unscheduled tray; never invent dates to position items on a timeline. |
| 20 · Dependency conflicts | Help me repair it | Explain the conflicting chain or dates and offer repair choices with an impact preview. Apply only after approval; preserve attempted intent while the user decides. |

## Confirmed — questions 21–24

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 21 · Non-drag task actions | Visible Move controls | Expose a Move action on items and a bulk-action toolbar for multi-selection. These controls must remain keyboard and assistive-technology accessible. |
| 22 · Future FolioDev introduction | Available with an introduction | Only when the later-phase feature ships, mark its launcher card as new and introduce capabilities on first opening. Request repository access explicitly. Keep FolioDev disabled in initial phases. |
| 23 · Accessibility preferences | Follow macOS accessibility settings | Follow system contrast and Reduce Motion, provide an editor text-size control, and avoid a large independent density/accessibility settings matrix. |
| 24 · Shortcuts and focus | Remap Folio commands | Allow app-command remapping with conflict warnings. Preserve standard macOS text-editing shortcuts; custom pane-order configuration was not selected. |

## Confirmed — questions 25–28

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 25 · Privacy comprehension | Explicit workspace-header labels | Label Plain vault versus Encrypted project explicitly in the header. Present local durability, package checkpoint and remote sync as separate states; never imply encryption with one generic lock icon. |
| 26 · Native editor acceptance | Both must pass before release | Native input correctness, selection/undo and strong large-document performance are all release gates, even if they extend the schedule. Benchmarks and Mac runtime evidence remain required. |
| 27 · Mac-before-Windows gate | “We dont move to windows until ma,c is fully secured” | Block Windows implementation until macOS passes agreed security-readiness gates; calendar dates do not override this. Evidence must define readiness, not an absolute zero-risk promise. The answer does not select the granularity or timing of Rust extraction; that detail remains an architecture decision to resolve. |
| 28 · Large-vault memory | Performance profiles | Provide Balanced, Low-memory and Large-vault profiles with measured cache/index budgets. All profiles must stay bounded and respond to OS memory pressure; no benchmark success is implied yet. |

## Confirmed — questions 29–32

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 29 · Search relevance | General notes, mainly English | Prioritise English/general-note title, phrase and tag relevance, with case/accent handling. This does not relax the separately required multilingual text-input correctness gate. |
| 30 · External changes | Update automatically when safe | Automatically reload notes without local edits. If local edits also exist, compare/merge against a base and preserve both versions when intent is ambiguous. Missed filesystem events still require reconciliation. |
| 31 · Durability and write activity | Short, bounded save delay | Use a roughly 250 ms coalescing window with a bounded maximum delay, not an indefinitely reset debounce. Show Saving until the real durability barrier succeeds; exact filesystem guarantees require tests. |
| 32 · Copied vault identity | Ask: restore or make a new workspace? | Explain restore/reconnect versus independent fork when a copied identity is detected. Do not silently combine histories or invent a new identity before confirmation. |

## Confirmed — questions 33–36

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 33 · Graph budgets | Adapt automatically to the Mac | Adapt visible-node, edge and label budgets to hardware and power conditions. Show cluster/omission counts; all content remains navigable through search/list views. |
| 34 · CPU/GPU split | Start simple and profile it | Start with background CPU layout and Metal drawing. Offload further work to GPU compute only after responsiveness, memory and energy measurements justify it. |
| 35 · Battery and thermal policy | Follow my performance profile | Use the selected performance profile for normal battery behaviour. Hard thermal/memory safeguards and durability protection still take precedence. |
| 36 · Large-note degradation | Offer the lighter mode first | Explain normal performance/formatting trade-offs and ask before changing to lightweight presentation. Preserve cursor and content; do not interpret this as permission to exceed hard resource-safety limits. |

## Confirmed — questions 37–40

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 37 · AI resource budgets | Adapt to my performance profile | Bound model context/concurrency according to the selected profile and real resource pressure. Writing/saves stay prioritised; disclose reductions in included context rather than silently truncating. |
| 38 · Unsupported speech | Keep text input available | Explain unavailable local speech, offer supported Apple language-asset downloads and retain text input. Do not introduce a second speech engine or cloud transcription as an automatic fallback. |
| 39 · .rdm checkpoint cost | Safe snapshots, less frequent checkpoints | Keep durable encrypted local saving independent of archive construction. For large projects checkpoint less often, with explicit pending/progress states and Save Package; retain atomic replacement rather than prematurely changing formats. |
| 40 · Password derivation | Strong, portable baseline | Prefer a reviewed cross-device Argon2id baseline and strict imported-parameter bounds. Exact implementation and parameters still require security review and interoperability tests. |

## Confirmed — questions 41–44

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 41 · Recovery and device enrolment | Recovery key plus trusted-device approval | Provide a verified, user-held recovery key and an existing trusted-device approval path for enrolment. No service-held decryption backdoor; losing all unlock material can still be irrecoverable. |
| 42 · Encrypted local residue | Encrypted persistent caches | Use reviewed encrypted persistent derived caches for fast reopening. Test indexes, WAL/temp files, previews, diagnostics and crash paths for unintended plaintext persistence; do not claim protection from a compromised unlocked OS. |
| 43 · CRDT evaluation | Long offline periods | Prioritise weeks-offline histories, safe convergence, memory growth and compaction in engine selection. Still retain input/undo correctness gates and explicit stale-device policies. |
| 44 · Revocation and unsynced work | Owner-reviewed import proposal | Reject revoked/old-epoch writes. Preserve a separate proposed patch that an authorised owner can explicitly review/import through an approved workflow; do not restore access or silently accept the original operations. |

## Confirmed — questions 45–48

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 45 · Suspicious sync history | Continue in a local branch | Suspend sync when rollback/equivocation is suspected, retain known local state and allow a recoverable local editing branch. Reconcile authenticated histories before publishing the branch. |
| 46 · Metadata exposure | Protect content; disclose metadata | Start with content confidentiality and honest disclosure of remaining size, timing, routing and account metadata. Extra padding/traffic-hiding profiles are not approved initial scope. |
| 47 · Developer-tool privilege | Start FolioDev read-only | When the later module ships, begin with source linking/preview. Defer LSP processes, executable tools and broader capabilities until their isolation has been reviewed; do not enable FolioDev now. |
| 48 · Windows evaluation gate | Defer the toolkit decision | Defer even Windows toolkit evaluation until macOS passes the security-readiness gate. The baseline Tauri preference is no longer an approved implementation decision. |

## Confirmed — questions 49–50

| Question | Personal choice | Implementation consequence |
|---|---|---|
| 49 · Android scope | Keep Android read-only for this roadmap | Phase 4 is read-only vault access/viewing. Remove light editing from approved roadmap scope; any later editing requires a separately approved scope and full process-death, provider, sync and key-loss gates. |
| 50 · Release trust | No exceptions to release blockers | All defined signing, notarization, integrity, dependency, migration, recovery and critical-security gates must pass. Missing/unrun evidence is blocking; no exception or waiver path may bypass a required gate. |

## Open

All 50 questions have an explicit answer. Implementation and verification remain separate.

## Build direction

Start a genuine native macOS project under `native/`, separate from the frozen browser design prototype. The first increment establishes the launcher, adaptive editor layout, explicit note creation, native text editing and paste-notification contract. The filesystem, journal, index, graph, encrypted container and AI integrations must be delivered and tested as later increments rather than simulated as working features.

## Verification boundary

The workspace is Linux. A Swift toolchain can compile and test the platform-independent core here; the Mac SDK and Xcode are unavailable. macOS compilation, AppKit/Metal runtime behaviour, accessibility and native performance remain unverified until run on a Mac.

## Latest delivery direction

The user wants the approved Mac feature set completed before their own testing, not another request to test an incomplete app. Engineering testing continues during construction. Feature completeness and release/security readiness still require distinct evidence. Deferred FolioDev/Windows/Android scope remains as recorded above unless explicitly revised. Unnecessary duplicate exports and obsolete build scratch should be removed while preserving source, decisions, useful evidence and the approved logo.

## Progress reporting and pace

The user requests a completion percentage and a summary of completed work in every user-facing update. Percentages must be explicitly estimated, tied to the approved Mac scope, and separate from release/security readiness. Work should be careful and security-led, not rushed to raise the percentage. Owner testing remains on hold until the approved feature set and mandatory gates are complete.
