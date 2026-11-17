import Foundation
import CoreMedia
import os
import VirtualCameraKit

/// Thread-safe wrapper around `FrameRateEstimator`. `FrameTap` records from the
/// capture queue; the UI reads from the main actor.
///
/// This only *reports* the real rate. It never triggers a correction on its own:
/// re-asserting the frame rate whenever it drifts is the rejected watchdog
/// approach (PLAN.md §3). `CameraViewModel.reassertSettings` reads it once, at
/// a client arrival or popover open, to decide whether a forced renegotiation
/// is needed.
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
