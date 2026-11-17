import CoreMedia
import Testing
@testable import LensBarCore

@Suite("VirtualCameraDemandGate")
struct VirtualCameraDemandGateTests {

    @Test("First client adds the demand once")
    func firstClientAdds() {
        var gate = VirtualCameraDemandGate()
        #expect(gate.clientsChanged(to: 1) == .addDemand)
        #expect(gate.clientsChanged(to: 2) == .none)
        #expect(gate.demanding)
    }

    @Test("Zero clients with no demand does nothing")
    func zeroWhileIdle() {
        var gate = VirtualCameraDemandGate()
        #expect(gate.clientsChanged(to: 0) == .none)
        #expect(gate.pendingToken == nil)
    }

    @Test("Last client leaving removes the demand only after the grace period")
    func graceThenRemove() {
        var gate = VirtualCameraDemandGate()
        _ = gate.clientsChanged(to: 1)
        let action = gate.clientsChanged(to: 0)
        guard case .scheduleRemoval(let token) = action else {
            Issue.record("expected scheduleRemoval, got \(action)")
            return
        }
        #expect(gate.demanding)
        #expect(gate.graceExpired(token: token) == .removeDemand)
        #expect(!gate.demanding)
        // A late duplicate expiry is ignored.
        #expect(gate.graceExpired(token: token) == .none)
    }

    @Test("A client returning within the grace period keeps the demand")
    func quickRetrigger() {
        var gate = VirtualCameraDemandGate()
        _ = gate.clientsChanged(to: 1)
        guard case .scheduleRemoval(let token) = gate.clientsChanged(to: 0) else {
            Issue.record("expected scheduleRemoval")
            return
        }
        // Zoom toggles video: back to one client before the grace expires.
        #expect(gate.clientsChanged(to: 1) == .none)
        #expect(gate.graceExpired(token: token) == .none)
        #expect(gate.demanding)
    }

    @Test("Only the newest scheduled removal can fire")
    func staleTokenIgnored() {
        var gate = VirtualCameraDemandGate()
        _ = gate.clientsChanged(to: 1)
        guard case .scheduleRemoval(let first) = gate.clientsChanged(to: 0) else {
            Issue.record("expected scheduleRemoval")
            return
        }
        _ = gate.clientsChanged(to: 1)
        guard case .scheduleRemoval(let second) = gate.clientsChanged(to: 0) else {
            Issue.record("expected scheduleRemoval")
            return
        }
        #expect(first != second)
        #expect(gate.graceExpired(token: first) == .none)
        #expect(gate.demanding)
        #expect(gate.graceExpired(token: second) == .removeDemand)
    }

    @Test("Repeated zero reports don't reschedule")
    func repeatedZero() {
        var gate = VirtualCameraDemandGate()
        _ = gate.clientsChanged(to: 1)
        guard case .scheduleRemoval(let token) = gate.clientsChanged(to: 0) else {
            Issue.record("expected scheduleRemoval")
            return
        }
        // The safety poll or a device-vanished report says 0 again.
        #expect(gate.clientsChanged(to: 0) == .none)
        #expect(gate.graceExpired(token: token) == .removeDemand)
    }

    @Test("Negative counts are treated as zero")
    func negativeCount() {
        var gate = VirtualCameraDemandGate()
        #expect(gate.clientsChanged(to: -3) == .none)
        #expect(gate.clients == 0)
    }
}

@Suite("VirtualCameraEndpoint sink selection")
struct VirtualCameraEndpointTests {

    @Test("Picks the stream with sink direction (0), not the first stream")
    func picksSink() {
        #expect(VirtualCameraEndpoint.sinkStream(in: [(10, 1), (11, 0)]) == 11)
    }

    @Test("No sink stream, or unreadable directions, gives nil")
    func noSink() {
        #expect(VirtualCameraEndpoint.sinkStream(in: [(10, 1)]) == nil)
        #expect(VirtualCameraEndpoint.sinkStream(in: [(10, nil), (11, nil)]) == nil)
        #expect(VirtualCameraEndpoint.sinkStream(in: []) == nil)
    }
}

@Suite("VirtualCameraSink")
struct VirtualCameraSinkTests {

    private func makeSampleBuffer(pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            nil, &pixelBuffer)
        let pb = try #require(pixelBuffer)
        var desc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                     formatDescriptionOut: &desc)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                 formatDescription: try #require(desc),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try #require(sample)
    }

    @Test("Re-stamping replaces the presentation time and keeps the image")
    func restamp() throws {
        let original = try makeSampleBuffer(pts: CMTime(value: 7, timescale: 1))
        let host = CMTime(value: 123_456, timescale: 1_000)
        let copy = try #require(VirtualCameraSink.restamped(original, at: host))
        #expect(CMSampleBufferGetPresentationTimeStamp(copy) == host)
        #expect(CMSampleBufferGetDuration(copy) == CMTime(value: 1, timescale: 25))
        #expect(CMSampleBufferGetImageBuffer(copy) === CMSampleBufferGetImageBuffer(original))
        // The original is untouched.
        #expect(CMSampleBufferGetPresentationTimeStamp(original) == CMTime(value: 7, timescale: 1))
    }

    @Test("Frames enqueued while detached are dropped silently")
    func detachedEnqueueIsNoop() throws {
        let sink = VirtualCameraSink()
        sink.enqueue(try makeSampleBuffer(pts: CMTime(value: 1, timescale: 25)))
        #expect(sink.drainStats() == VirtualCameraSink.Stats())
    }
}
