import Foundation
import AppKit
import AVFoundation
import Speech
import FolioCore

/// macOS-26 path only: no cloud recognizer, DictationTranscriber fallback,
/// AVAudioFile recording or automatic asset download.
@MainActor
final class AppleSpeechService {
    @MainActor
    private final class Operation {
        let run: VoiceRun
        let emit: @MainActor @Sendable (NativeVoiceEvent) -> Void
        var engine: AVAudioEngine?
        var ring: PCMFrameQueue?
        var pipeline: AppleSpeechPipeline?
        var preparing = true
        var stopRequested = false
        var discard = false
        var microphoneOn = false
        var tapInstalled = false
        var reason: VoiceStopReason = .requested
        var observers: [(NotificationCenter, NSObjectProtocol)] = []
        var monitor: Task<Void, Never>?
        var finishDeadline: Task<Void, Never>?
        var cleanup: Task<Void, Never>?
        init(run: VoiceRun, emit: @escaping @MainActor @Sendable (NativeVoiceEvent) -> Void) { self.run = run; self.emit = emit }
    }
    private var active: Operation?
    private var downloading = false
    private var reservations = SpeechReservationLedger(restoring: UserDefaults.standard.stringArray(forKey: "ownedSpeechReservations") ?? [])

    var hasActiveResources: Bool { active != nil }
    func capability(for identifier: String) async -> SpeechCapability {
        guard validLocale(identifier), SpeechTranscriber.isAvailable else { return .unavailable("On-device SpeechTranscriber is unavailable on this device.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else { return .unavailable("The requested language is not supported by the local transcriber.") }
        let transcriber = makeTranscriber(locale)
        let tag = locale.identifier(.bcp47)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready(locale: tag)
        case .supported: return .needsAssets(locale: tag)
        case .downloading: return .downloading(locale: tag)
        case .unsupported: return .unavailable("The resolved language configuration is unsupported.")
        @unknown default: return .unavailable("Unknown local speech asset status.")
        }
    }
    func microphonePermission() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
    /// Called only in response to the owner's Record action, never on launch,
    /// capability checking, downloading, or displaying a text editor.
    func requestMicrophonePermission() async -> MicrophonePermission {
        if microphonePermission() == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        return microphonePermission()
    }
    func installAssets(_ consent: SpeechAssetConsent) async throws {
        guard active == nil, !downloading else { throw VoiceError.busy }
        downloading = true; defer { downloading = false }
        let locale = Locale(identifier: consent.locale)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale), supported.identifier(.bcp47) == consent.locale else { throw VoiceError.unsupportedLocale }
        let transcriber = makeTranscriber(supported)
        let newly = try await AssetInventory.reserve(locale: supported)
        reservations.didReserve(locale: consent.locale, newlyReserved: newly); saveReservationLedger()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        // Apple may retry failed downloads later. The UI rechecks status instead
        // of claiming cancellation or successful installation from this call alone.
    }
    func releaseOwnedAssets(locale identifier: String) async throws {
        guard active == nil, !downloading, reservations.mayRelease(identifier) else { throw VoiceError.invalidState }
        let released = await AssetInventory.release(reservedLocale: Locale(identifier: identifier))
        reservations.didRelease(identifier, succeeded: released); saveReservationLedger()
    }
    func start(_ run: VoiceRun, emit: @escaping @MainActor @Sendable (NativeVoiceEvent) -> Void) async {
        if Task.isCancelled { emit(.microphoneStopped(run.id)); emit(.closed(run.id, .requested)); return }
        guard active == nil, !downloading else { emit(.fault(run.id, .processingFailure)); emit(.microphoneStopped(run.id)); emit(.closed(run.id, .processingFailure)); return }
        let op = Operation(run: run, emit: emit); active = op
        do {
            guard microphonePermission() == .granted, SpeechTranscriber.isAvailable else { throw VoiceError.permissionDenied }
            let locale = Locale(identifier: run.locale)
            let transcriber = makeTranscriber(locale)
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw VoiceError.assetsMissing }
            try ensureCurrent(op)
            let newly = try await AssetInventory.reserve(locale: locale)
            reservations.didReserve(locale: run.locale, newlyReserved: newly); saveReservationLedger()
            try ensureCurrent(op)
            let engine = AVAudioEngine(); op.engine = engine
            let hardware = engine.inputNode.outputFormat(forBus: 0)
            guard hardware.commonFormat == .pcmFormatFloat32, !hardware.isInterleaved,
                  hardware.sampleRate.isFinite, (8000...192000).contains(hardware.sampleRate),
                  (1...8).contains(hardware.channelCount) else { throw VoiceError.invalidAudioFormat }
            let ring = try PCMFrameQueue(channels: Int(hardware.channelCount), maximumFrames: 4096, slots: run.limits.queueSlots)
            op.ring = ring
            let pipeline = AppleSpeechPipeline(run: run, transcriber: transcriber,
                source: .init(sampleRate: hardware.sampleRate, channels: hardware.channelCount), queue: ring) { event in
                    await emit(event)
                }
            op.pipeline = pipeline
            try await pipeline.prepare()
            try ensureCurrent(op)
            // Start the bounded consumer before enabling the audio producer.
            // An empty queue does not activate the microphone.
            try await pipeline.beginFeeding()
            try ensureCurrent(op)
            guard NSApplication.shared.isActive else { op.reason = .applicationInactive; throw CancellationError() }
            let channels = hardware.channelCount, rate = hardware.sampleRate
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardware) { [ring] buffer, _ in
                // No Task, lock, disk write, logging or buffer allocation here.
                // Actual callback timing/AVFoundation behaviour needs Mac profiling.
                guard buffer.frameLength > 0 else { return }
                guard buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved,
                      buffer.format.channelCount == channels, buffer.format.sampleRate == rate,
                      let planes = buffer.floatChannelData else { ring.flagInvalidFormat(); return }
                _ = ring.offerPlanar(planes, frames: buffer.frameLength)
            }
            op.tapInstalled = true
            engine.prepare()
            try ensureCurrent(op)
            try engine.start()
            op.microphoneOn = true; emit(.microphoneStarted(run.id))
            installObservers(op)
            op.preparing = false
            if op.stopRequested { await finish(op) }
        } catch {
            op.preparing = false
            if !op.stopRequested && !op.discard && op.reason == .requested { op.reason = .processingFailure }
            if !(error is CancellationError) && !op.discard { emit(.fault(run.id, op.reason)) }
            haltMicrophone(op)
            await finish(op)
        }
    }
    func stop(runID: UUID, discard: Bool, reason: VoiceStopReason) async {
        guard let op = active, op.run.id == runID else { return }
        op.stopRequested = true; op.discard = op.discard || discard
        if reason != .requested { op.reason = reason }
        haltMicrophone(op) // Before any await: never wait for model teardown to stop capture.
        if discard || op.preparing, let pipeline = op.pipeline { await pipeline.requestCancellation() }
        if !op.preparing { await finish(op) }
    }
    /// Used for application/window/sleep paths before scheduling asynchronous
    /// finalization. It stops the producer even if analysis is unresponsive.
    func haltForInterruption(_ reason: VoiceStopReason) {
        guard let op = active else { return }
        op.stopRequested = true; op.reason = reason
        haltMicrophone(op); op.emit(.fault(op.run.id, reason))
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !op.preparing { await self.finish(op) }
        }
    }
    private func haltMicrophone(_ op: Operation) {
        op.ring?.closeInput()
        op.engine?.stop()
        if op.tapInstalled { op.engine?.inputNode.removeTap(onBus: 0); op.tapInstalled = false }
        op.microphoneOn = false; op.monitor?.cancel(); op.monitor = nil
        op.emit(.microphoneStopped(op.run.id))
    }
    private func finish(_ op: Operation) async {
        if let task = op.cleanup { await task.value; return }
        haltMicrophone(op)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            op.finishDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self, self.active === op else { return }
                op.reason = .finalizationTimeout
                op.emit(.fault(op.run.id, .finalizationTimeout))
                await op.pipeline?.requestCancellation()
            }
            await op.pipeline?.finish(discard: op.discard)
            op.finishDeadline?.cancel(); op.finishDeadline = nil
            for (center, token) in op.observers { center.removeObserver(token) }; op.observers = []
            // Callback closure lifetime + completed consumer teardown keep the C
            // queue alive until no producer/consumer can still reference it.
            do { try op.ring?.scrubAfterStopped() } catch { op.reason = .processingFailure }
            op.pipeline = nil; op.ring = nil; op.engine = nil
            if self.active === op { self.active = nil }
            op.emit(.closed(op.run.id, op.reason))
        }
        op.cleanup = task
        await task.value
        op.cleanup = nil
    }
    private func ensureCurrent(_ op: Operation) throws {
        guard active === op, !op.stopRequested, !op.discard, !Task.isCancelled else { throw CancellationError() }
    }
    private func installObservers(_ op: Operation) {
        let id = op.run.id
        func add(_ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil, reason: VoiceStopReason) {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active?.run.id == id else { return }
                    self.haltForInterruption(reason)
                }
            }
            op.observers.append((center, token))
        }
        add(.default, NSApplication.willResignActiveNotification, reason: .applicationInactive)
        add(.default, NSWindow.willCloseNotification, reason: .applicationInactive)
        add(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification, reason: .applicationInactive)
        add(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, reason: .systemSleep)
        add(.default, .AVAudioEngineConfigurationChange, object: op.engine, reason: .deviceChanged)
        let began = ProcessInfo.processInfo.systemUptime
        op.monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.active === op, op.microphoneOn else { return }
                if self.microphonePermission() != .granted || op.engine?.isRunning != true { self.haltForInterruption(.deviceChanged); return }
                if (ProcessInfo.processInfo.systemUptime - began) * 1000 >= Double(op.run.limits.maximumMilliseconds) {
                    self.haltForInterruption(.durationLimit); return
                }
            }
        }
    }
    private func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    }
    private func validLocale(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }
    private func saveReservationLedger() { UserDefaults.standard.set(reservations.ownedLocales, forKey: "ownedSpeechReservations") }
}
