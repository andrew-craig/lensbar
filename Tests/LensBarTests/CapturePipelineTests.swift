import Testing
@testable import LensBarCore

@Suite("CaptureDemandSet state machine")
struct CaptureDemandSetTests {

    @Test("Starts idle")
    func startsIdle() {
        let set = CaptureDemandSet()
        #expect(!set.shouldRun)
        #expect(set.active.isEmpty)
    }

    @Test("First demand starts, last removal stops")
    func singleSource() {
        var set = CaptureDemandSet()
        #expect(set.insert(.popover) == .start)
        #expect(set.shouldRun)
        #expect(set.remove(.popover) == .stop)
        #expect(!set.shouldRun)
    }

    @Test("Second source joining a running pipeline is not a transition")
    func overlappingSources() {
        var set = CaptureDemandSet()
        #expect(set.insert(.popover) == .start)
        #expect(set.insert(.virtualCamera) == nil)
        // Popover closes while a client is still streaming: keep running.
        #expect(set.remove(.popover) == nil)
        #expect(set.shouldRun)
        #expect(set.remove(.virtualCamera) == .stop)
    }

    @Test("Repeated insert and remove are idempotent")
    func idempotent() {
        var set = CaptureDemandSet()
        #expect(set.insert(.virtualCamera) == .start)
        #expect(set.insert(.virtualCamera) == nil)
        #expect(set.remove(.virtualCamera) == .stop)
        #expect(set.remove(.virtualCamera) == nil)
        #expect(set.remove(.popover) == nil)
    }
}

@Suite("CapturePipeline hooks")
@MainActor
struct CapturePipelineTests {

    final class Counter {
        var starts = 0
        var stops = 0
    }

    private func makePipeline(_ counter: Counter) -> CapturePipeline {
        CapturePipeline(start: { counter.starts += 1 }, stop: { counter.stops += 1 })
    }

    @Test("Popover open/close drives start/stop once each")
    func popoverCycle() {
        let counter = Counter()
        let pipeline = makePipeline(counter)
        pipeline.add(.popover)
        pipeline.add(.popover)
        #expect(counter.starts == 1)
        pipeline.remove(.popover)
        #expect(counter.stops == 1)
        #expect(!pipeline.shouldRun)
    }

    @Test("Session outlives the popover while the virtual camera has clients")
    func outlivesPopover() {
        let counter = Counter()
        let pipeline = makePipeline(counter)
        pipeline.add(.popover)
        pipeline.add(.virtualCamera)
        pipeline.remove(.popover)
        #expect(counter.starts == 1)
        #expect(counter.stops == 0)
        #expect(pipeline.shouldRun)
        pipeline.add(.popover)
        #expect(counter.starts == 1)
        pipeline.remove(.popover)
        pipeline.remove(.virtualCamera)
        #expect(counter.stops == 1)
    }
}
