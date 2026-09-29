import Foundation
// `AVAudioPCMBuffer.floatChannelData` and the converter callbacks are not
// annotated `Sendable`; under Swift 6 strict concurrency the pre-concurrency
// import keeps this audio pipeline compiling without weakening the checks on
// Folio's own types.
@preconcurrency import AVFoundation
import Speech
import CoreMedia
import FolioCore

struct SpeechAudioFormat: Sendable {
    let sampleRate: Double
    let channels: UInt32
}
enum NativeVoiceEvent: Sendable {
    case microphoneStarted(UUID)
    case microphoneStopped(UUID)
    case segment(UUID, SpeechSegment)
    case fault(UUID, VoiceStopReason)
    case closed(UUID, VoiceStopReason)
}

/// Conversion and analyzer work are isolated off the UI actor. The realtime
/// input callback only writes to a bounded, preallocated PCM queue.
actor AppleSpeechPipeline {
    private let run: VoiceRun
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let source: SpeechAudioFormat
    private let queue: PCMFrameQueue
    private let emit: @Sendable (NativeVoiceEvent) async -> Void
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var input: AsyncStream<AnalyzerInput>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var feeder: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var cancelling = false
    private var finishingRequested = false
    private var faultReported = false

    init(run: VoiceRun, transcriber: SpeechTranscriber, source: SpeechAudioFormat,
         queue: PCMFrameQueue, emit: @escaping @Sendable (NativeVoiceEvent) async -> Void) {
        self.run = run; self.transcriber = transcriber; self.source = source; self.queue = queue; self.emit = emit
        analyzer = SpeechAnalyzer(modules: [transcriber]) // Conservative system resource limits stay enabled.
    }
    func prepare() async throws {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                              channels: source.channels, interleaved: false) else { throw VoiceError.invalidAudioFormat }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat),
              format.sampleRate.isFinite, (8000...192000).contains(format.sampleRate),
              (1...8).contains(format.channelCount) else { throw VoiceError.invalidAudioFormat }
        guard !cancelling else { throw CancellationError() }
        sourceFormat = inputFormat; outputFormat = format
        if inputFormat != format {
            guard let created = AVAudioConverter(from: inputFormat, to: format) else { throw VoiceError.invalidAudioFormat }
            created.primeMethod = .none
            converter = created
        }
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(4))
        input = pair.stream; continuation = pair.continuation
        results = Task { await self.consumeResults() }
        try await analyzer.prepareToAnalyze(in: format)
        guard !cancelling else { throw CancellationError() }
        try await analyzer.start(inputSequence: pair.stream)
    }
    func beginFeeding() throws {
        guard !cancelling, sourceFormat != nil, outputFormat != nil, feeder == nil else { throw VoiceError.invalidState }
        feeder = Task { await self.feed() }
    }
    func requestCancellation() async {
        cancelling = true; finishingRequested = true; queue.closeInput()
        feeder?.cancel(); continuation?.finish()
        await analyzer.cancelAndFinishNow()
    }
    func finish(discard: Bool) async {
        finishingRequested = true
        if discard { await requestCancellation() }
        if let feeder { await feeder.value }
        continuation?.finish()
        if cancelling {
            await analyzer.cancelAndFinishNow()
        } else {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { await report(.processingFailure); await analyzer.cancelAndFinishNow() }
        }
        if let results { await results.value }
        self.feeder = nil; self.results = nil; continuation = nil; input = nil
        converter = nil; sourceFormat = nil; outputFormat = nil
    }
    private func feed() async {
        var raw = [Float](repeating: 0, count: queue.maximumFrames * queue.channels)
        defer {
            for index in raw.indices { raw[index] = 0 }
            continuation?.finish()
        }
        do {
            while !cancelling && !Task.isCancelled {
                if queue.fault != .accepted {
                    await report(queue.fault == .overflow ? .audioOverflow : .deviceChanged)
                    queue.closeInput(); break
                }
                let count = try raw.withUnsafeMutableBufferPointer { try queue.read(into: $0) }
                if let count {
                    guard let sourceFormat, let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
                          let planes = buffer.floatChannelData else { throw VoiceError.invalidAudioFormat }
                    buffer.frameLength = AVAudioFrameCount(count)
                    raw.withUnsafeBufferPointer { source in
                        guard let address = source.baseAddress else { return }
                        for channel in 0..<queue.channels {
                            // Typed copy instead of `memcpy`: Swift 6 rejects the
                            // raw-pointer form without a manual rebound.
                            planes[channel].update(from: address.advanced(by: channel * count), count: count)
                        }
                    }
                    try offer(try convert(buffer))
                } else if queue.isDrained { break }
                else { try await Task.sleep(for: .milliseconds(8)) }
            }
            if !cancelling && !Task.isCancelled && queue.fault == .accepted { try flushConverter() }
        } catch is CancellationError { }
        catch VoiceError.audioOverflow { await report(.audioOverflow); queue.closeInput() }
        catch { await report(.processingFailure); queue.closeInput() }
    }
    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter, let outputFormat else { return buffer }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = ceil(Double(buffer.frameLength) * ratio) + 64
        guard capacity.isFinite, capacity > 0, capacity <= 131072,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else { throw VoiceError.invalidAudioFormat }
        var supplied = false, problem: NSError?
        let status = converter.convert(to: output, error: &problem) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, problem == nil else { throw VoiceError.captureFailed }
        return output
    }
    private func flushConverter() throws {
        guard let converter, let outputFormat else { return }
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else { throw VoiceError.invalidAudioFormat }
            var problem: NSError?
            let status = converter.convert(to: output, error: &problem) { _, state in state.pointee = .endOfStream; return nil }
            guard status != .error, problem == nil else { throw VoiceError.captureFailed }
            try offer(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        throw VoiceError.captureFailed // No unbounded flushing or hidden tail loss.
    }
    private func offer(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        guard let continuation else { throw VoiceError.invalidState }
        switch continuation.yield(AnalyzerInput(buffer: buffer)) {
        case .enqueued: break
        case .dropped: throw VoiceError.audioOverflow
        case .terminated: throw VoiceError.captureFailed
        @unknown default: throw VoiceError.captureFailed
        }
    }
    private func consumeResults() async {
        do {
            for try await result in transcriber.results {
                if cancelling || Task.isCancelled { return }
                let text = String(result.text.characters)
                if text.isEmpty { continue }
                let start = CMTimeGetSeconds(result.range.start), end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                guard start.isFinite, end.isFinite, start >= 0, end > start,
                      end * 1000 <= Double(run.limits.maximumMilliseconds + 10_000) else { throw VoiceError.invalidResult }
                let segment = SpeechSegment(startMilliseconds: Int64((start * 1000).rounded()),
                    endMilliseconds: Int64((end * 1000).rounded()), text: text, isFinal: result.isFinal)
                await emit(.segment(run.id, segment))
            }
            if !cancelling && !finishingRequested { await report(.processingFailure) }
        } catch {
            if !cancelling && !Task.isCancelled { await report(.processingFailure) }
        }
    }
    private func report(_ reason: VoiceStopReason) async {
        guard !faultReported else { return }
        faultReported = true
        await emit(.fault(run.id, reason))
    }
}
