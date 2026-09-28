# Capture and review — Increment 05

**Core flow tested on Linux; Mac provider/UI source added. Live model inference, native editor transactions and speech recording have not been verified or completed here. This is not security certification.**

## Authority and trust boundaries

The capture provider interface accepts only fixed instructions, explicit JSON source material, an output-token ceiling and a request fingerprint. It receives no vault/file handles, command registry, network client, key broker, graph mutation API or application tools.

The production adapter selects `SystemLanguageModel.default`, creates a fresh single-turn session and passes an explicitly empty tool list. It has no HTTP/private-cloud/alternate-model fallback. Availability is checked before generation. The app does not add microphone or networking entitlements for this increment.

Captured material and model output are **untrusted data**. Instruction/data separation helps structure requests; it is not a proof that a language model cannot follow prompt injection. The material protection is that generated text has no application authority, no autonomous apply path and no unapproved provider context. Output quality, model refusals and prompt-injection behaviour still need actual model evaluation.

## Input and context consent

- Nothing from the target note or linked notes is automatically inserted into the prompt.
- The visible input is sent with the explicitly added whole-note snapshots or selected excerpts only.
- Context is frozen; the app does not secretly re-read a broader/newer note for generation.
- Duplicate-note and cross-project/session context are rejected.
- Related full notes beyond the current budget are rejected, not truncated or summarised behind the user's approval.
- Transcript text requires confirmation before restructuring. Editing input or changing the capture revision invalidates prior confirmation.
- Increment 05 was manual-transcript-only. Increment 06 adds native microphone/Apple speech source and a separate reviewed handoff, but real recording/ASR remains unverified; see `SPEECH-SECURITY-CONTRACT.md`.
- Replacement selections are bound to the source digest and generation before generation, not merely to an old numeric offset.
- Unicode range checks reject surrogate/grapheme splits. Front matter, BOM and existing line endings are protected from unintended replacement.

The inspection UI exposes the exact JSON data; directional controls are displayed visibly. Raw capture input and proposals remain memory-only until explicitly applied. There is no prompt/transcript logging or automatic draft persistence in this increment. Ordinary accepted note content will enter the existing plaintext vault/journal/index lifecycle.

## Resource and cancellation policy

The three existing resource profiles configure bounded input/context/prompt bytes, output bytes/tokens and waiting time. Byte budgets are **not exact token counts**; tokenisation and actual memory use depend on the model/language. A model-side context failure requires an explicit narrower request—no silent context pruning or cloud retry.

Only one provider job is active. Cancellation/timeout returns to the waiting UI and invalidates its result. The broker deliberately retains the busy slot until the provider actually finishes, so an uncooperative operation cannot cause parallel retry accumulation. A late completion is discarded. This does not claim the app can forcibly kill framework/model computation. The UI exposes a status check while cancellation remains in progress.

The provider uses a token ceiling against unexpectedly verbose output. This can cut a response short; output validation/review does not prove factual or grammatical completeness. Input remains available for an explicit retry.

## Review and application

- There is no preselected review mode. The owner chooses whole draft, individual sections or detailed comparison.
- Detailed comparison uses a bounded line-level diff (not an unbounded full-vault algorithm); unselected changes preserve original lines.
- Section selection supports append or an explicit selected passage. It cannot silently replace the entire old body while dropping unselected original sections; detailed comparison handles that case.
- Every approval is tied to the current proposal ID. Correcting generated Markdown or comparing against newer writing creates a new ID and clears old approvals.
- A changed target digest **or edit generation** blocks application, including change-and-undo/ABA cases.
- Rebasing a selected passage requires a fresh, explicit current selection. Old offsets are not guessed into newer writing.
- A model-generated front-matter block, NUL/control data, excessive output or an unclosed code fence is rejected. HTML/images/links/directional formatting are disclosed for review; they do not gain execution/network permission.
- The final application plan is validated again against the actual native editor buffer and workspace/note/editor lifetime at dispatch time.
- Mac source applies through one native text/undo transaction, not a provider filesystem write. During that transaction, delegate forwarding is suppressed until the exact postcondition is verified; unexpected native transformation requests rollback instead of autosaving unreviewed bytes.
- Successful application means **changed in the editor**, not saved to disk. The normal journalled save pipeline still has to succeed.
- Explicit capture undo requires the exact applied digest/generation. It cannot delete newer writing; normal native Undo remains available separately.

The native transaction/rollback, IME, selection and undo paths are source only until exercised in Xcode/AppKit. Core tests cannot certify these UI behaviours.

## Limits and remaining work

The system is not an autonomous agent. It does not turn generated checkboxes into roadmap mutations, execute code, browse links or create files on its own. It does not guarantee truthful summaries, semantic preservation, complete Markdown, perfect prompt-injection resistance, memory zeroisation or safety under a compromised unlocked OS.

Remaining work includes real Foundation Models SDK/runtime tests, output-quality/refusal/context-window evaluation, native editor transaction and rollback validation, resource/thermal/memory-pressure testing, richer capture input integration, Apple speech/permission/assets, and independent security review. Encrypted-project capture boundaries must be reviewed separately when `.rdm` exists.

## Evidence

The new tests exercise explicit-context omission canaries, transcript confirmation, scope/range binding, bounded diff reconstruction, selected approval, stale targets/undo, provider-slot exclusivity, timeout/cancellation and late-result rejection. The capture workflow probe uses a **fixed test fixture provider, not an LLM**, with actual temporary vault writes and reopen/recovery.

## Primary API references used for the unverified Mac adapter

Apple's availability/session example: [5](https://developer.apple.com/videos/play/wwdc2025/286/).

Exact API references checked while writing the adapter:

- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init(model:tools:instructions:)
- https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models
- https://developer.apple.com/documentation/foundationmodels/generationoptions

The adapter uses the baseline macOS 26 interface; it does not opt into a remote model. A real Mac SDK build is still required to establish source/API compatibility.
