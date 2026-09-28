import Foundation
import FolioFileIO

public enum PCMQueueResult: Int32, Equatable, Sendable {
    case accepted = 0, empty = 1, closed = 2, overflow = 3, invalid = 4, insufficientCapacity = 5
}

/// A preallocated single-producer/single-consumer Float32 queue. The native tap
/// calls only offerPlanar; conversion, allocation and async work happen elsewhere.
/// Lifetime ownership must stop producer/consumer before releasing this object.
public final class PCMFrameQueue: @unchecked Sendable {
    private let handle: OpaquePointer
    public let channels: Int
    public let maximumFrames: Int
    public let slots: Int
    public init(channels: Int, maximumFrames: Int = 4096, slots: Int = 8) throws {
        guard (1...8).contains(channels), (1...4096).contains(maximumFrames), [4,8,16].contains(slots),
              let handle = folio_pcm_create(UInt32(channels), UInt32(maximumFrames), UInt32(slots)) else { throw VoiceError.invalidAudioFormat }
        self.handle = handle; self.channels = channels; self.maximumFrames = maximumFrames; self.slots = slots
    }
    deinit { folio_pcm_destroy(handle) }
    public var allocatedBytes: Int { Int(folio_pcm_allocated_bytes(handle)) }
    public var fault: PCMQueueResult { PCMQueueResult(rawValue: folio_pcm_fault(handle)) ?? .invalid }
    public var isDrained: Bool { folio_pcm_is_drained(handle) != 0 }
    public func closeInput() { folio_pcm_close(handle) }
    public func flagInvalidFormat() { folio_pcm_mark_invalid(handle) }

    @discardableResult
    public func offerPlanar(_ planes: UnsafePointer<UnsafeMutablePointer<Float>>, frames: UInt32) -> PCMQueueResult {
        PCMQueueResult(rawValue: folio_pcm_push_planar(handle, planes, frames)) ?? .invalid
    }
    /// Convenience for non-realtime tests/producers. Native audio uses pointer
    /// planes directly and never creates a Swift array in its callback.
    @discardableResult
    public func offer(samples: [Float], frames: Int) -> PCMQueueResult {
        guard frames > 0, frames <= maximumFrames, samples.count == frames * channels else { return .invalid }
        return samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .invalid }
            return PCMQueueResult(rawValue: folio_pcm_push(handle, base, UInt32(frames))) ?? .invalid
        }
    }
    /// Single consumer only. `destination` is reusable and must hold all channels.
    public func read(into destination: UnsafeMutableBufferPointer<Float>) throws -> Int? {
        guard let base = destination.baseAddress else { throw VoiceError.invalidAudioFormat }
        var frames: UInt32 = 0
        let result = PCMQueueResult(rawValue: folio_pcm_pop(handle, base, destination.count, &frames)) ?? .invalid
        if result == .empty { return nil }
        guard result == .accepted else { throw VoiceError.invalidAudioFormat }
        return Int(frames)
    }
    /// Best-effort clearing of this queue's allocations, not OS/framework copies.
    /// Call only after native producer and consumer teardown acknowledgements.
    public func scrubAfterStopped() throws {
        guard folio_pcm_scrub_stopped(handle) == 0 else { throw VoiceError.resourceNotReleased }
    }
}
