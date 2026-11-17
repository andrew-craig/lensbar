import Foundation
import CoreMedia
import os

/// Estimates a stream's frame rate from presentation timestamps over a sliding
/// window. Pure value type so it can be unit-tested (and later moved into
/// `VirtualCameraKit`).
///
/// - Rate is `(n - 1) / (last - first)` over the timestamps inside `window`.
/// - A timestamp that goes backwards is a discontinuity (new session, clock
///   reset): the window restarts from it. An equal timestamp is ignored.
/// - The estimate goes `nil` once no frame has *arrived* for `staleAfter`
///   seconds, so a stalled stream doesn't keep showing its last rate.
struct FrameRateEstimator: Sendable {
    var window: Double
    var staleAfter: Double

    private var timestamps: [Double] = []
    private var lastArrival: Double?

    init(window: Double = 2.0, staleAfter: Double = 1.0) {
        self.window = window
        self.staleAfter = staleAfter
    }

    mutating func record(presentationTime pts: Double, arrival: Double) {
        if let last = timestamps.last {
            if pts == last { return }
            if pts < last { timestamps.removeAll(keepingCapacity: true) }
        }
        timestamps.append(pts)
        lastArrival = arrival
        let cutoff = pts - window
        if let firstKept = timestamps.firstIndex(where: { $0 >= cutoff }), firstKept > 0 {
            timestamps.removeFirst(firstKept)
        }
    }

    func framesPerSecond(now: Double) -> Double? {
        guard let lastArrival, now - lastArrival <= staleAfter else { return nil }
        guard timestamps.count >= 2,
              let first = timestamps.first,
              let last = timestamps.last,
              last > first else { return nil }
        return Double(timestamps.count - 1) / (last - first)
    }

    mutating func reset() {
        timestamps.removeAll(keepingCapacity: true)
        lastArrival = nil
    }
}

/// Thread-safe wrapper around `FrameRateEstimator`. `FrameTap` records from the
/// capture queue; the UI reads from the main actor.
///
/// This only *reports* the real rate. It never corrects the device: re-asserting
/// the frame rate when it drifts is the rejected watchdog approach (PLAN.md §3).
final class RateMonitor: Sendable {
    private let estimator: OSAllocatedUnfairLock<FrameRateEstimator>

    init(window: Double = 2.0, staleAfter: Double = 1.0) {
        estimator = OSAllocatedUnfairLock(initialState: FrameRateEstimator(window: window, staleAfter: staleAfter))
    }

    static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func record(presentationTime: CMTime) {
        guard presentationTime.isNumeric else { return }
        let pts = presentationTime.seconds
        let now = Self.hostNow()
        estimator.withLock { $0.record(presentationTime: pts, arrival: now) }
    }

    /// Measured frames per second, or nil when there isn't enough recent data.
    func framesPerSecond() -> Double? {
        let now = Self.hostNow()
        return estimator.withLock { $0.framesPerSecond(now: now) }
    }

    func reset() {
        estimator.withLock { $0.reset() }
    }
}
