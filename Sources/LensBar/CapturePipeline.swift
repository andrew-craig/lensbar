import Foundation

/// Something that needs the physical camera's capture session to be running.
public enum CaptureDemand: String, Hashable, CaseIterable, Sendable {
    /// The menu-bar popover is open (preview + live controls).
    case popover
    /// At least one client app is streaming LensBar Camera (Phase 3).
    case virtualCamera
}

/// Pure state machine over the active demand sources. The session should run
/// while any demand is active; only the empty ↔ non-empty edges produce a
/// transition, so adding a second source to a running pipeline (or removing
/// one of two) leaves the session alone.
struct CaptureDemandSet: Equatable, Sendable {
    enum Transition: Equatable, Sendable {
        case start
        case stop
    }

    private(set) var active: Set<CaptureDemand> = []

    var shouldRun: Bool { !active.isEmpty }

    @discardableResult
    mutating func insert(_ demand: CaptureDemand) -> Transition? {
        let wasRunning = shouldRun
        active.insert(demand)
        return !wasRunning && shouldRun ? .start : nil
    }

    @discardableResult
    mutating func remove(_ demand: CaptureDemand) -> Transition? {
        let wasRunning = shouldRun
        active.remove(demand)
        return wasRunning && !shouldRun ? .stop : nil
    }
}

/// Owns the capture session's lifetime policy and the per-frame plumbing
/// shared by every consumer of the physical camera.
///
/// The session lifetime is decoupled from the popover: it runs while the
/// popover is open **or** the virtual camera has clients (PLAN.md §4.4). The
/// actual open/close work (device choice, snapshot restore, UVC probe) stays
/// in `CameraViewModel` and is invoked through the `start` / `stop` hooks.
@MainActor
final class CapturePipeline {

    private(set) var demand = CaptureDemandSet()

    /// Measures the real stream rate from frame timestamps. Report only.
    let rateMonitor: RateMonitor

    /// Video data output delegate attached to every session the pipeline opens.
    let frameTap: FrameTap

    private let start: @MainActor () -> Void
    private let stop: @MainActor () -> Void

    init(start: @escaping @MainActor () -> Void, stop: @escaping @MainActor () -> Void) {
        self.start = start
        self.stop = stop
        let monitor = RateMonitor()
        self.rateMonitor = monitor
        self.frameTap = FrameTap(rateMonitor: monitor)
    }

    var shouldRun: Bool { demand.shouldRun }

    func add(_ source: CaptureDemand) {
        if demand.insert(source) == .start { start() }
    }

    func remove(_ source: CaptureDemand) {
        if demand.remove(source) == .stop { stop() }
    }
}
