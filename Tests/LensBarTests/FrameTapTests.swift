import CoreMedia
import Foundation
import Testing
@testable import LensBarCore

@Suite("FrameTap handler storage")
struct FrameTapTests {

    /// Regression: reading the handler must not re-wrap the stored closure.
    /// It once lived directly in `OSAllocatedUnfairLock<FrameHandler?>`, where
    /// each `withLock { $0 }` wrote back a reabstraction-thunked copy, so the
    /// call chain grew by a thunk pair per frame until the capture queue's
    /// stack overflowed after a few minutes of streaming.
    @Test("Repeated reads leave the handler callable at constant depth")
    func repeatedReadsDoNotGrowHandler() throws {
        let tap = FrameTap(rateMonitor: RateMonitor())
        let calls = Counter()
        tap.setFrameHandler { _ in calls.increment() }
        // ~10 minutes at 60 fps — well past the old overflow point.
        for _ in 0..<40_000 {
            _ = tap.currentHandler()
        }
        let handler = tap.currentHandler()
        #expect(handler != nil)
        let buffer = try CMSampleBuffer(dataBuffer: nil, formatDescription: nil, numSamples: 0,
                                        sampleTimings: [], sampleSizes: [])
        handler?(buffer)
        #expect(calls.value == 1)
    }

    @Test("Clearing the handler")
    func clear() {
        let tap = FrameTap(rateMonitor: RateMonitor())
        tap.setFrameHandler { _ in }
        tap.setFrameHandler(nil)
        #expect(tap.currentHandler() == nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
