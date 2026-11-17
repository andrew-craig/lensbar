import Testing
@testable import LensBarCore

@Suite("FrameRateEstimator")
struct FrameRateEstimatorTests {

    /// Feed `count` frames at `fps` starting at `start`; arrival == pts.
    private func feed(_ est: inout FrameRateEstimator, fps: Double, count: Int, start: Double) -> Double {
        var t = start
        for _ in 0..<count {
            est.record(presentationTime: t, arrival: t)
            t += 1 / fps
        }
        return t - 1 / fps
    }

    @Test("No estimate from zero or one frame")
    func notEnoughData() {
        var est = FrameRateEstimator()
        #expect(est.framesPerSecond(now: 0) == nil)
        est.record(presentationTime: 10, arrival: 10)
        #expect(est.framesPerSecond(now: 10) == nil)
    }

    @Test("Steady 25 fps reads 25", arguments: [25.0, 30.0, 29.97, 60.0])
    func steadyRate(fps: Double) throws {
        var est = FrameRateEstimator()
        let last = feed(&est, fps: fps, count: 100, start: 1000)
        let measured = try #require(est.framesPerSecond(now: last))
        #expect(abs(measured - fps) < 0.01)
    }

    @Test("Window forgets the old rate after a change")
    func followsRateChange() throws {
        var est = FrameRateEstimator(window: 2.0)
        var last = feed(&est, fps: 30, count: 90, start: 0)
        // 3 s at 25 fps: longer than the window, so no 30 fps frames remain.
        last = feed(&est, fps: 25, count: 75, start: last + 1.0 / 25)
        let measured = try #require(est.framesPerSecond(now: last))
        #expect(abs(measured - 25) < 0.01)
    }

    @Test("Goes stale when frames stop arriving")
    func stale() {
        var est = FrameRateEstimator(staleAfter: 1.0)
        let last = feed(&est, fps: 25, count: 50, start: 0)
        #expect(est.framesPerSecond(now: last + 0.5) != nil)
        #expect(est.framesPerSecond(now: last + 1.5) == nil)
    }

    @Test("Backwards timestamp restarts the window")
    func discontinuity() throws {
        var est = FrameRateEstimator()
        _ = feed(&est, fps: 30, count: 30, start: 500)
        // New session: timestamps jump back.
        let last = feed(&est, fps: 25, count: 10, start: 100)
        let measured = try #require(est.framesPerSecond(now: last))
        #expect(abs(measured - 25) < 0.01)
    }

    @Test("Duplicate timestamps are ignored")
    func duplicates() throws {
        var est = FrameRateEstimator()
        for i in 0..<50 {
            let t = Double(i) / 25
            est.record(presentationTime: t, arrival: t)
            est.record(presentationTime: t, arrival: t)
        }
        let measured = try #require(est.framesPerSecond(now: 49.0 / 25))
        #expect(abs(measured - 25) < 0.01)
    }

    @Test("Reset clears the estimate")
    func reset() {
        var est = FrameRateEstimator()
        let last = feed(&est, fps: 25, count: 50, start: 0)
        est.reset()
        #expect(est.framesPerSecond(now: last) == nil)
    }
}
