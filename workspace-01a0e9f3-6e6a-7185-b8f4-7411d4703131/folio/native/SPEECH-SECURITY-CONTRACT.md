# On-device voice capture — Increment 06

**Core policy and synthetic audio transport are tested on Linux. The Mac microphone, SpeechAnalyzer, converter, permissions and UI have not been run here. No real speech accuracy, real-time or security approval is claimed.**

## Consent is not a side effect of opening a note

- Capability checking does not open the microphone or request a download.
- Only the explicit Record action can request microphone permission and begin preparation.
- A missing language model requires a separate, locale-bound download confirmation. No automatic download is attached to Record.
- Unsupported device/language or denied/restricted permission leaves text entry available; there is no SFSpeechRecognizer/cloud or alternate-engine fallback.
- The source targets macOS 26 SpeechTranscriber/SpeechAnalyzer. It does not depend on the newer macOS 27 CaptureInputSequenceProvider/AnalyzerInputConverter helpers.
- The app requests App Sandbox, user-selected-file read/write and audio-input capability, plus a specific microphone purpose string. It does not add an app networking entitlement or request legacy server-backed speech-recognition authorization.

Apple manages speech language assets, their sharing and later retries. The download prompt explains the network/storage operation. Folio records only its own newly acquired locale reservations and does not evict another subsystem's reservations to make space. Releasing a reservation does not promise immediate deletion of system-managed assets.

## State and scope

A voice run is bound to a project/session/note/editor identity and the exact capture-draft revision. Preparation, microphone-on, stopping, analyzer finalization, review and cancellation are distinct states.

- A permission reply arriving after Stop/Discard cannot start a microphone.
- A Stop click is **not** an off acknowledgement. The UI shows microphone use until the driver reports it stopped.
- Analyzer resources remain busy until teardown is acknowledged. A second recording is blocked during preparation/finalization/cancellation.
- Late events from older runs cannot change the current transcript.
- Reset/discard cannot pretend an active device or analyzer has already closed.
- Final transcripts are reviewed/corrected before use. A changed review revision or changed capture target/draft blocks handoff.
- Importing an explicitly reviewed transcript confirms that exact text in the capture core. It does not run AI, apply a proposal or save a note automatically.

The native controller guards each asynchronous preparation boundary and checks cancellation before enabling the producer. Device reconfiguration, permission loss, app inactivity, recorder disappearance, sleep and duration limits request shutdown. The producer is stopped synchronously before waiting for analyzer finalization. Actual ordering under Mac interruptions remains a required runtime gate.

## Audio transport and memory

The microphone source uses AVAudioEngine. Its tap copies Float32 planar samples into an allocation-bounded C queue rather than writing audio files or spawning an async task per callback.

- Fixed channel/frame/slot bounds; no per-frame queue allocation.
- Single producer/single consumer with atomic indices, bounded copying and latched invalid/overflow faults.
- Reentrant producer/consumer use is rejected, not treated as a supported MPMC queue.
- NaN/infinite samples, format changes and capacity violations fail instead of silently entering the decoder.
- Overflow stops capture and marks the transcript incomplete; audio gaps are not hidden as a successful recording.
- Conversion and analyzer delivery happen off the UI actor through a separately bounded input sequence.
- Producer/consumer teardown precedes buffer clearing. The queue's own storage is cleared on consumption/teardown; this is not a guarantee about OS swap, framework copies or a compromised process.

Profiles currently bound recordings to 60/120/180 seconds, transcripts to 16/24/32 KiB and raw queue slots to 4/8/8. These limits are implementation bounds, not measured Mac CPU/RAM/battery targets. Hardware capture is restricted to supported finite Float32/noninterleaved configurations; unsupported formats fail clearly.

No AVAudioFile recorder, playback store or automatic audio export exists. Folio's source does not save a raw recording. The reviewed text can later become ordinary plaintext note/journal/index content through explicit capture approval.

## Results and corrections

Volatile hypotheses replace overlapping provisional ranges instead of being appended repeatedly. Final ranges are not silently rewritten by later hypotheses. Results are bounded and ordered by their audio ranges; invalid overlap/timing/content is rejected.

A normal stop may still receive final results while the microphone is already off. Review begins only after analyzer closure. If the tail remains provisional, a limit/interruption occurred or processing failed, the retained text is marked incomplete and needs explicit acknowledgement before use.

The UI does not invent speaker identities or confidence percentages. Native speech accuracy, timestamp rounding, segment boundaries and language-specific text joining need corpus/device testing. The person can correct the full transcript. Corrections invalidate previous approval.

## Cancellation and failure

No asynchronous request is assumed to stop merely because a task was cancelled. The analyzer is asked to cancel, the microphone is stopped independently, late text is discarded on an explicit discard, and the session retains its busy state until closure.

A bounded finalization wait requests cancellation rather than claiming success. If the OS/framework never acknowledges teardown, the app must remain visibly blocked from another capture. Native failure messages do not log raw audio/transcript diagnostics.

## Evidence boundary

This increment adds lifecycle/consent/transcript/handoff tests and PCM queue tests. A generated speech probe uses synthetic samples and scripted result events, then the actual reviewed-capture and journalled-store core. It is **not a microphone or ASR benchmark**.

A standalone synthetic C harness passes AddressSanitizer and UndefinedBehaviorSanitizer checks, including 100,000 accepted threaded frames. It is not ThreadSanitizer, proof of general race freedom, validation of AVAudioEngine callback scheduling, or a substitute for native real-time profiling.

Before release, engineers must run real Mac TCC permission/revocation, all stop/close/sleep/device-change races, converter tail/format checks, actual asset lifecycle, transcription/correction accuracy, native UI/accessibility and performance tests, plus independent privacy/security review. Owner testing remains on hold.

## API references and sample attribution

On-device transcription and separate asset download are described in Apple's WWDC25 session: [2](https://developer.apple.com/videos/play/wwdc2025/277/).

Primary API pages checked while writing the unverified adapter:

- https://developer.apple.com/documentation/speech/speechtranscriber
- https://developer.apple.com/documentation/speech/speechanalyzer
- https://developer.apple.com/documentation/speech/assetinventory
- https://developer.apple.com/documentation/speech/assetinventory/reserve(locale:)
- https://developer.apple.com/documentation/speech/assetinstallationrequest/downloadandinstall()
- https://developer.apple.com/documentation/speech/speechtranscriber/result
- https://developer.apple.com/documentation/speech/captureinputsequenceprovider
- https://developer.apple.com/documentation/speech/analyzerinputconverter

The AVAudioEngine/AVAudioConverter integration was written with reference to Apple's macOS-26-capable sample. The sample's unbounded stream, raw audio file storage and automatic follow-on generation behaviours were not adopted. Applicable sample notice: `Notices/Apple-Speech-Sample-License.txt`.
