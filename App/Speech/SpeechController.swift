import Foundation
import AppKit
import Observation
import FolioCore

@MainActor
@Observable
final class SpeechController {
    var machine = SpeechCaptureMachine()
    var localeIdentifier = Locale.current.identifier(.bcp47)
    var capability: SpeechCapability = .unavailable("Check on-device language support before recording.")
    var showingRecorder = false
    var checking = false
    var downloading = false
    var starting = false
    var failure: String?
    var status = "No microphone is active. Speech stays local; text input is always available."
    var acknowledgesIncomplete = false
    @ObservationIgnored private let driver = AppleSpeechService()
    @ObservationIgnored private var checkEpoch = UUID()
    @ObservationIgnored private var startEpoch = UUID()
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?

    var hasWork: Bool { starting || downloading || machine.isBusy || !machine.transcript.isEmpty }
    var blocksCaptureChanges: Bool { starting || machine.isBusy || !machine.transcript.isEmpty }
    var isMicrophoneActive: Bool { machine.microphoneActive }
    var mayStart: Bool {
        guard !starting, !downloading, !checking, !machine.isBusy, machine.transcript.isEmpty else { return false }
        if case .ready = capability { return true }; return false
    }
    func setLocale(_ value: String) {
        guard !starting, !downloading, !machine.isBusy else { return }
        localeIdentifier = value; checkEpoch = UUID()
        capability = .unavailable("The language changed. Check support before recording.")
        failure = nil
    }
    func checkSupport() async {
        guard !starting, !downloading, !machine.isBusy else { return }
        let epoch = UUID(); checkEpoch = epoch
        checking = true; failure = nil
        let value = await driver.capability(for: localeIdentifier)
        guard checkEpoch == epoch else { return }
        capability = value; checking = false
    }
    func requestAssetDownload() async {
        guard !starting, !downloading, !machine.isBusy, case .needsAssets(let locale) = capability else { return }
        let alert = NSAlert()
        alert.messageText = "Download Apple speech support for \(locale)?"
        alert.informativeText = "This explicitly requests a network download and disk storage for Apple's shared language assets. macOS manages their size, updates and later retries. No microphone is opened and no recorded audio is sent by this request."
        alert.addButton(withTitle: "Download Language Assets"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let consent = try SpeechAssetConsent.approve(capability: capability, displayedLocale: locale, userConfirmedDownload: true)
            downloading = true; failure = nil; status = "Downloading system-managed language assets. Recording has not started."
            defer { downloading = false }
            try await driver.installAssets(consent)
            capability = await driver.capability(for: locale)
            status = "Language assets checked. Recording still requires a separate Record action."
        } catch {
            capability = await driver.capability(for: locale)
            failure = "The asset request did not complete. macOS may retry later; check support again. No microphone was opened."
        }
    }
    func releaseOwnedAssets() async {
        guard let locale = capability.locale, !machine.isBusy, !starting, !downloading else { return }
        do { try await driver.releaseOwnedAssets(locale: locale); await checkSupport(); status = "Folio released its own reservation. macOS decides when shared assets can be removed." }
        catch { failure = "Folio cannot release that reservation: it may be active or owned by another subsystem." }
    }
    func start(draft: CaptureDraft, profile: SearchProfile) {
        guard mayStart else { failure = VoiceError.busy.localizedDescription; return }
        starting = true; failure = nil; acknowledgesIncomplete = false
        let token = UUID(); startEpoch = token
        let locale = localeIdentifier
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == self.startEpoch { self.starting = false } }
            do {
                let checked = await self.driver.capability(for: locale)
                guard token == self.startEpoch, !Task.isCancelled else { return }
                self.capability = checked
                let permission = self.driver.microphonePermission()
                let run = try self.machine.begin(binding: .init(draft: draft), capability: checked,
                    permission: permission, profile: profile, userPressedRecord: true)
                self.status = permission == .notDetermined ? "Waiting for microphone permission. Capture has not started." : "Preparing on-device speech; microphone not yet active."
                if permission == .notDetermined {
                    let result = await self.driver.requestMicrophonePermission()
                    let proceed = try self.machine.permissionResolved(runID: run.id, result: result)
                    if !proceed || Task.isCancelled {
                        try self.machine.microphoneDidStop(runID: run.id)
                        try self.machine.providerDidClose(runID: run.id)
                        self.status = "Recording cancelled before the microphone started."
                        return
                    }
                }
                guard self.machine.mayStartMicrophone(runID: run.id), token == self.startEpoch, !Task.isCancelled else {
                    try self.machine.microphoneDidStop(runID: run.id); try self.machine.providerDidClose(runID: run.id); return
                }
                await self.driver.start(run) { [weak self] event in self?.receive(event) }
            } catch {
                self.failure = (error as? VoiceError)?.localizedDescription ?? "Local speech setup failed. Text input remains available."
                // If preparation never reached the driver, there cannot be an
                // active microphone. Close only that non-driver reservation.
                if !self.driver.hasActiveResources, let run = self.machine.run, !self.machine.microphoneActive {
                    try? self.machine.providerDidClose(runID: run.id, reason: .processingFailure)
                }
            }
        }
    }
    func stop(discard: Bool = false, reason: VoiceStopReason = .requested) {
        guard let run = machine.run, machine.isBusy else {
            if starting { startEpoch = UUID(); startTask?.cancel(); starting = false }
            return
        }
        do { try machine.requestStop(runID: run.id, discard: discard, reason: reason) }
        catch { failure = error.localizedDescription; return }
        startTask?.cancel(); elapsedTask?.cancel(); elapsedTask = nil
        status = machine.microphoneActive ? "Stopping microphone; waiting for driver acknowledgement…" : "Microphone is off; waiting for analyzer teardown…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.driver.stop(runID: run.id, discard: discard, reason: reason)
        }
    }
    /// Stops the actual producer synchronously on MainActor before app/window
    /// disappearance. Analyzer finalisation remains asynchronous and visible.
    func haltForDisappearance(_ reason: VoiceStopReason = .requested) {
        if let run = machine.run, machine.isBusy { try? machine.requestStop(runID: run.id, discard: false, reason: reason) }
        driver.haltForInterruption(reason)
        stop(discard: false, reason: reason)
    }
    func discardAfterStopped() {
        if machine.isBusy || starting { stop(discard: true); return }
        do { try machine.resetAfterClosed(); failure = nil; acknowledgesIncomplete = false; status = "Transcript discarded from Folio's in-memory speech state." }
        catch { failure = error.localizedDescription }
    }
    func editTranscript(_ value: String) {
        do { try machine.editTranscript(value); acknowledgesIncomplete = false; failure = nil }
        catch { failure = error.localizedDescription }
    }
    func reviewedTranscript() throws -> ReviewedVoiceTranscript {
        try machine.approveForUse(expectedRevision: machine.reviewRevision, acknowledgesIncomplete: acknowledgesIncomplete)
    }
    func consumedTranscript() {
        do { try machine.resetAfterClosed(); failure = nil; showingRecorder = false; status = "Reviewed transcript moved into Capture. AI still requires an explicit Generate action." }
        catch { failure = error.localizedDescription }
    }
    private func receive(_ event: NativeVoiceEvent) {
        do {
            switch event {
            case .microphoneStarted(let id):
                try machine.microphoneDidStart(runID: id)
                status = "Microphone active. Results remain provisional until you stop and review."
                let began = ProcessInfo.processInfo.systemUptime
                elapsedTask?.cancel()
                elapsedTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, self.machine.run?.id == id, self.machine.microphoneActive else { return }
                        let milliseconds = Int64(max(0, (ProcessInfo.processInfo.systemUptime - began) * 1000))
                        if (try? self.machine.updateElapsed(milliseconds, runID: id)) == true { self.stop(reason: .durationLimit); return }
                    }
                }
            case .microphoneStopped(let id):
                try machine.microphoneDidStop(runID: id)
                elapsedTask?.cancel(); elapsedTask = nil
                status = "Microphone off. Finalising/releasing the local analyzer…"
            case .segment(let id, let segment): try machine.accept(segment, runID: id)
            case .fault(let id, let reason):
                guard machine.run?.id == id else { return }
                try machine.requestStop(runID: id, discard: false, reason: reason)
                failure = reason.warning
                Task { @MainActor [weak self] in await self?.driver.stop(runID: id, discard: false, reason: reason) }
            case .closed(let id, let reason):
                try machine.providerDidClose(runID: id, reason: reason)
                starting = false; elapsedTask?.cancel(); elapsedTask = nil
                status = machine.phase == .review ? "Microphone and analyzer closed. Correct the transcript, then explicitly approve it." : "Speech session closed. Text input remains available."
            }
        } catch VoiceError.staleRun {
            // A callback never receives authority merely because it arrives late.
        } catch {
            failure = (error as? VoiceError)?.localizedDescription ?? VoiceError.captureFailed.localizedDescription
            if let id = machine.run?.id, machine.isBusy {
                try? machine.requestStop(runID: id, discard: false, reason: .processingFailure)
                Task { @MainActor [weak self] in await self?.driver.stop(runID: id, discard: false, reason: .processingFailure) }
            }
        }
    }
}
