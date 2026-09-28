import XCTest
import Foundation
import Dispatch
@testable import FolioCore

final class PCMFrameQueueTests: XCTestCase, @unchecked Sendable {
    func testBoundsRejectUnsupportedAllocations() {
        XCTAssertThrowsError(try PCMFrameQueue(channels: 0))
        XCTAssertThrowsError(try PCMFrameQueue(channels: 9))
        XCTAssertThrowsError(try PCMFrameQueue(channels: 1, maximumFrames: 0))
        XCTAssertThrowsError(try PCMFrameQueue(channels: 1, maximumFrames: 4097))
        XCTAssertThrowsError(try PCMFrameQueue(channels: 1, slots: 7))
    }
    func testAllocationHasAFixedUpperBound() throws {
        let queue = try PCMFrameQueue(channels: 8, maximumFrames: 4096, slots: 16)
        XCTAssertLessThan(queue.allocatedBytes, 2 * 1024 * 1024 + 4096)
        queue.closeInput(); try queue.scrubAfterStopped()
    }
    func testPlanarChannelsRoundTripWithoutBorrowingSourceStorage() throws {
        let queue = try PCMFrameQueue(channels: 2, maximumFrames: 4, slots: 4)
        var source: [Float] = [1,2,3,4, 5,6,7,8]
        XCTAssertEqual(queue.offer(samples: source, frames: 4), .accepted)
        source = Array(repeating: 99, count: 8)
        var output = [Float](repeating: 0, count: 8)
        let count = try output.withUnsafeMutableBufferPointer { try queue.read(into: $0) }
        XCTAssertEqual(count, 4); XCTAssertEqual(output, [1,2,3,4,5,6,7,8])
        XCTAssertEqual(source, Array(repeating: 99, count: 8))
    }
    func testPointerPlanesHaveTheSameLayoutAsTheNativeTap() throws {
        let queue = try PCMFrameQueue(channels: 2, maximumFrames: 4, slots: 4)
        var left: [Float] = [0.1,0.2], right: [Float] = [0.3,0.4]
        let result = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                let planes = [l.baseAddress!, r.baseAddress!]
                return planes.withUnsafeBufferPointer { queue.offerPlanar($0.baseAddress!, frames: 2) }
            }
        }
        XCTAssertEqual(result, .accepted)
        var resultData = [Float](repeating: 0, count: 8)
        let count = try resultData.withUnsafeMutableBufferPointer { try queue.read(into: $0) }
        XCTAssertEqual(count, 2); XCTAssertEqual(Array(resultData.prefix(4)), [0.1,0.2,0.3,0.4])
    }
    func testOverflowIsLatchedRatherThanSilentlyDroppingAFrame() throws {
        let queue = try PCMFrameQueue(channels: 1, maximumFrames: 2, slots: 4)
        for number in 0..<4 { XCTAssertEqual(queue.offer(samples: [Float(number)], frames: 1), .accepted) }
        XCTAssertEqual(queue.offer(samples: [99], frames: 1), .overflow)
        XCTAssertEqual(queue.fault, .overflow)
        var output = [Float](repeating: 0, count: 2)
        for number in 0..<4 {
            let count = try output.withUnsafeMutableBufferPointer { try queue.read(into: $0) }
            XCTAssertEqual(count, 1); XCTAssertEqual(output[0], Float(number))
        }
        XCTAssertNil(try output.withUnsafeMutableBufferPointer { try queue.read(into: $0) })
    }
    func testNonFiniteAudioIsRejectedBeforePublishing() throws {
        let queue = try PCMFrameQueue(channels: 1, maximumFrames: 4, slots: 4)
        XCTAssertEqual(queue.offer(samples: [.nan], frames: 1), .invalid)
        XCTAssertEqual(queue.fault, .invalid)
        var output = [Float](repeating: 0, count: 4)
        XCTAssertNil(try output.withUnsafeMutableBufferPointer { try queue.read(into: $0) })
    }
    func testTooSmallConsumerBufferDoesNotConsumeTheFrame() throws {
        let queue = try PCMFrameQueue(channels: 2, maximumFrames: 4, slots: 4)
        XCTAssertEqual(queue.offer(samples: [1,2,3,4], frames: 2), .accepted)
        var tiny: [Float] = [0]
        XCTAssertThrowsError(try tiny.withUnsafeMutableBufferPointer { try queue.read(into: $0) })
        var enough = [Float](repeating: 0, count: 8)
        XCTAssertEqual(try enough.withUnsafeMutableBufferPointer { try queue.read(into: $0) }, 2)
        XCTAssertEqual(Array(enough.prefix(4)), [1,2,3,4])
    }
    func testCloseStopsNewOffersAndDrainsAlreadyAcceptedFrames() throws {
        let queue = try PCMFrameQueue(channels: 1, maximumFrames: 2, slots: 4)
        _ = queue.offer(samples: [7], frames: 1)
        queue.closeInput()
        XCTAssertFalse(queue.isDrained)
        XCTAssertEqual(queue.offer(samples: [8], frames: 1), .closed)
        var output: [Float] = [0,0]
        XCTAssertEqual(try output.withUnsafeMutableBufferPointer { try queue.read(into: $0) }, 1)
        XCTAssertTrue(queue.isDrained)
        try queue.scrubAfterStopped()
    }
    func testScrubIsRejectedWhileProducerIsEnabled() throws {
        let queue = try PCMFrameQueue(channels: 1)
        XCTAssertThrowsError(try queue.scrubAfterStopped())
        queue.closeInput(); XCTAssertNoThrow(try queue.scrubAfterStopped())
    }
    func testDeterministicQueueModelAcrossWraparound() throws {
        let queue = try PCMFrameQueue(channels: 1, maximumFrames: 2, slots: 4)
        var expected: [Float] = [], output: [Float] = [0,0]
        for step in 0..<3000 {
            if step % 3 != 0 && expected.count < 4 {
                XCTAssertEqual(queue.offer(samples: [Float(step)], frames: 1), .accepted); expected.append(Float(step))
            } else if !expected.isEmpty {
                XCTAssertEqual(try output.withUnsafeMutableBufferPointer { try queue.read(into: $0) }, 1)
                XCTAssertEqual(output[0], expected.removeFirst())
            }
        }
    }
    func testConcurrentSingleProducerConsumerPreserveAcceptedOrder() throws {
        final class Failures: @unchecked Sendable {
            private let lock = NSLock(); private var messages: [String] = []
            func add(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
            var result: [String] { lock.lock(); defer { lock.unlock() }; return messages }
        }
        let queue = try PCMFrameQueue(channels: 1, maximumFrames: 1, slots: 16)
        let failures = Failures(), group = DispatchGroup(), count = 10_000
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        group.enter()
        DispatchQueue(label: "folio.test.pcm.producer").async {
            defer { queue.closeInput(); group.leave() }
            for i in 0..<count {
                while queue.offer(samples: [Float(i)], frames: 1) != .accepted {
                    if DispatchTime.now().uptimeNanoseconds > deadline { failures.add("Producer timed out"); return }
                    Thread.sleep(forTimeInterval: 0.00001)
                }
            }
        }
        group.enter()
        DispatchQueue(label: "folio.test.pcm.consumer").async {
            defer { group.leave() }
            var next = 0, output: [Float] = [0]
            while next < count {
                if DispatchTime.now().uptimeNanoseconds > deadline { failures.add("Consumer timed out"); return }
                do {
                    if let _ = try output.withUnsafeMutableBufferPointer({ try queue.read(into: $0) }) {
                        if output[0] != Float(next) { failures.add("Out-of-order frame"); return }
                        next += 1
                    } else { Thread.sleep(forTimeInterval: 0.00001) }
                } catch { failures.add("Unexpected queue error"); return }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 6), .success)
        XCTAssertTrue(failures.result.isEmpty, failures.result.joined(separator: "; "))
        // The stress producer deliberately retries a full queue. Production does
        // NOT retry/drop silently: a latched overrun stops recording for review.
        XCTAssertTrue(queue.isDrained)
        try queue.scrubAfterStopped()
    }
    func testFormatChangeFaultClosesFutureWrites() throws {
        let queue = try PCMFrameQueue(channels: 1, maximumFrames: 8, slots: 4)
        queue.flagInvalidFormat()
        XCTAssertEqual(queue.fault, .invalid)
        XCTAssertEqual(queue.offer(samples: [1], frames: 1), .closed)
        XCTAssertTrue(queue.isDrained)
    }

}
