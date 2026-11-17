// Phase 0 spike (throwaway): push frames into a CMIO camera extension's sink
// stream from an unsandboxed process via the CoreMediaIO C API.

import CoreMedia
import CoreMediaIO
import Foundation

final class SinkFeeder {
    private let deviceID: CMIOObjectID
    private let streamID: CMIOStreamID
    private let queue: CMSimpleQueue
    private let lock = NSLock()
    private var enqueued = 0
    private var dropped = 0

    /// Finds the CMIO device whose UID matches and opens its sink stream.
    init?(deviceUID: String) {
        // Let this process see DAL/extension devices.
        var allow: UInt32 = 1
        var allowAddr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &allowAddr, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)

        guard let dev = SinkFeeder.devices().first(where: { SinkFeeder.uid(of: $0) == deviceUID }) else {
            log("sink: no CMIO device with UID \(deviceUID). Devices: \(SinkFeeder.devices().map { SinkFeeder.uid(of: $0) ?? "?" })")
            return nil
        }
        let streams = SinkFeeder.streams(of: dev)
        for s in streams {
            log("sink: stream \(s) direction=\(SinkFeeder.direction(of: s))")
        }
        // Sink stream = CMIO direction 0 (input to the device); source = 1. Fall back to the second stream.
        guard let sinkStream = streams.first(where: { SinkFeeder.direction(of: $0) == 0 }) ?? (streams.count > 1 ? streams[1] : nil) else {
            log("sink: device has no sink stream")
            return nil
        }
        var q: Unmanaged<CMSimpleQueue>?
        let err = CMIOStreamCopyBufferQueue(sinkStream, { _, _, _ in }, nil, &q)
        guard err == noErr, let qq = q?.takeRetainedValue() else {
            log("sink: CMIOStreamCopyBufferQueue failed \(err)")
            return nil
        }
        let startErr = CMIODeviceStartStream(dev, sinkStream)
        guard startErr == noErr else {
            log("sink: CMIODeviceStartStream failed \(startErr)")
            return nil
        }
        deviceID = dev
        streamID = sinkStream
        queue = qq
        log("sink: feeding device \(dev) stream \(sinkStream), queue capacity \(CMSimpleQueueGetCapacity(qq))")
    }

    func stop() {
        CMIODeviceStopStream(deviceID, streamID)
    }

    /// Re-stamps on the host clock and enqueues; drops when the queue is full.
    func enqueue(_ sb: CMSampleBuffer) {
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) {
            lock.lock(); dropped += 1; lock.unlock()
            return
        }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                                    sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                    sampleBufferOut: &out) == noErr, let copy = out
        else { return }
        let st = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(copy).toOpaque())
        lock.lock()
        if st == noErr { enqueued += 1 } else { dropped += 1 }
        lock.unlock()
    }

    func drainStats() -> (Int, Int) {
        lock.lock(); defer { enqueued = 0; dropped = 0; lock.unlock() }
        return (enqueued, dropped)
    }

    // MARK: CMIO helpers

    private static func addr(_ sel: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func ids(of obj: CMIOObjectID, _ sel: Int) -> [CMIOObjectID] {
        var a = addr(sel)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(obj, &a, 0, nil, size, &used, &out) == noErr else { return [] }
        return out
    }

    static func devices() -> [CMIOObjectID] { ids(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) }
    static func streams(of dev: CMIOObjectID) -> [CMIOStreamID] { ids(of: dev, kCMIODevicePropertyStreams) }

    static func uid(of dev: CMIOObjectID) -> String? {
        var a = addr(kCMIODevicePropertyDeviceUID)
        var cf: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(dev, &a, 0, nil, size, &used, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }

    static func direction(of stream: CMIOStreamID) -> UInt32 {
        var a = addr(kCMIOStreamPropertyDirection)
        var d: UInt32 = 99
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(stream, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &d)
        return d
    }
}
