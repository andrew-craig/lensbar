import CoreMedia
import CoreMediaIO
import Foundation
import os

private let sinkLog = Logger(subsystem: "com.andrewcraig.LensBar", category: "VirtualCameraSink")

/// Pushes captured frames into LensBar Camera's sink stream through the
/// CoreMediaIO C API (`CMIOStreamCopyBufferQueue` + `CMIODeviceStartStream` +
/// `CMSimpleQueueEnqueue`, PLAN.md §4.3 A). The extension forwards them to
/// its source stream, whatever their size and rate (§4.5).
///
/// - `attach(to:)` / `detach()` are called from the main actor and do their
///   CMIO work on a private serial queue, so IPC never blocks the UI.
/// - `enqueue(_:)` is called on the capture queue for every frame. It
///   re-stamps the frame on the host clock and drops it when the CMIO queue
///   is full, rather than blocking the capture pipeline.
///
/// Frames enqueued while detached are dropped silently.
final class VirtualCameraSink: @unchecked Sendable {
    struct Stats: Equatable, Sendable {
        var enqueued = 0
        var dropped = 0
    }

    private let controlQueue = DispatchQueue(label: "com.lensbar.virtualcamera.sink")

    // Guarded by `lock`. Never held across CMIO control calls.
    private let lock = NSLock()
    private var queue: CMSimpleQueue?
    private var stats = Stats()

    // Only touched on `controlQueue`.
    private var endpoint: VirtualCameraEndpoint?

    /// Start feeding `endpoint`. Replaces any previous endpoint. No-op when
    /// already attached to the same one.
    func attach(to newEndpoint: VirtualCameraEndpoint) {
        controlQueue.async { [self] in
            guard endpoint != newEndpoint else { return }
            stopCurrent()
            var unmanaged: Unmanaged<CMSimpleQueue>?
            let copyStatus = CMIOStreamCopyBufferQueue(newEndpoint.sinkStream, { _, _, _ in }, nil, &unmanaged)
            guard copyStatus == noErr, let bufferQueue = unmanaged?.takeRetainedValue() else {
                sinkLog.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
                return
            }
            let startStatus = CMIODeviceStartStream(newEndpoint.device, newEndpoint.sinkStream)
            guard startStatus == noErr else {
                sinkLog.error("CMIODeviceStartStream failed: \(startStatus)")
                releaseQueue(of: newEndpoint.sinkStream)
                return
            }
            endpoint = newEndpoint
            lock.withLock { queue = bufferQueue }
            sinkLog.info("""
                sink attached: device \(newEndpoint.device) stream \(newEndpoint.sinkStream) \
                capacity \(CMSimpleQueueGetCapacity(bufferQueue))
                """)
        }
    }

    /// Stop feeding. Safe to call when not attached.
    func detach() {
        controlQueue.async { [self] in stopCurrent() }
    }

    /// Re-stamp on the host clock and enqueue. Drops on a full queue.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let queue else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            stats.dropped += 1
            return
        }
        guard let copy = Self.restamped(sampleBuffer, at: CMClockGetTime(CMClockGetHostTimeClock())) else {
            stats.dropped += 1
            return
        }
        // The queue takes ownership of one retain; the extension side
        // releases it after consuming. Undo the retain if the enqueue fails.
        let element = Unmanaged.passRetained(copy)
        if CMSimpleQueueEnqueue(queue, element: element.toOpaque()) == noErr {
            stats.enqueued += 1
        } else {
            element.release()
            stats.dropped += 1
        }
    }

    /// Counts since the last call.
    func drainStats() -> Stats {
        lock.withLock {
            defer { stats = Stats() }
            return stats
        }
    }

    /// A copy of `sampleBuffer` (sharing its pixel buffer) whose presentation
    /// time is `time`. AVFoundation's timestamps are usually already on the
    /// host clock, but re-stamping at enqueue time guarantees it and keeps
    /// the sequence monotonic across session restarts and device switches.
    static func restamped(_ sampleBuffer: CMSampleBuffer, at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing,
                                                           sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }

    // MARK: Private (controlQueue)

    private func stopCurrent() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard let current = endpoint else { return }
        endpoint = nil
        lock.withLock { queue = nil }
        // Both calls fail harmlessly if the device has already gone away
        // (extension restart, device replacement).
        let status = CMIODeviceStopStream(current.device, current.sinkStream)
        releaseQueue(of: current.sinkStream)
        sinkLog.info("sink detached: device \(current.device) stream \(current.sinkStream) status \(status)")
    }

    /// Calling `CMIOStreamCopyBufferQueue` with a nil callback releases the
    /// stream's hold on the queue.
    private func releaseQueue(of stream: CMIOStreamID) {
        var unused: Unmanaged<CMSimpleQueue>?
        _ = CMIOStreamCopyBufferQueue(stream, nil, nil, &unused)
    }
}
