import Foundation

/// Estimates a stream's frame rate from presentation timestamps over a sliding
/// window. Pure value type so it can be unit-tested, and has no AVFoundation or IOKit
/// dependency so the sandboxed extension can use it too.
///
/// - Rate is `(n - 1) / (last - first)` over the timestamps inside `window`.
/// - A timestamp that goes backwards is a discontinuity (new session, clock
///   reset): the window restarts from it. An equal timestamp is ignored.
/// - The estimate goes `nil` once no frame has *arrived* for `staleAfter`
///   seconds, so a stalled stream doesn't keep showing its last rate.
public struct FrameRateEstimator: Sendable {
    public var window: Double
    public var staleAfter: Double

    private var timestamps: [Double] = []
    private var lastArrival: Double?

    public init(window: Double = 2.0, staleAfter: Double = 1.0) {
        self.window = window
        self.staleAfter = staleAfter
    }

    public mutating func record(presentationTime pts: Double, arrival: Double) {
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

    public func framesPerSecond(now: Double) -> Double? {
        guard let lastArrival, now - lastArrival <= staleAfter else { return nil }
        guard timestamps.count >= 2,
              let first = timestamps.first,
              let last = timestamps.last,
              last > first else { return nil }
        return Double(timestamps.count - 1) / (last - first)
    }

    public mutating func reset() {
        timestamps.removeAll(keepingCapacity: true)
        lastArrival = nil
    }
}
