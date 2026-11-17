import Foundation

/// Turns LensBar Camera's client count into the `.virtualCamera` capture
/// demand, with a grace period on the way down (PLAN.md §6, Phase 3).
///
/// Zoom stops and restarts the source stream on every video toggle and camera
/// switch (about six sessions in two minutes in the spike), so dropping the
/// demand the moment the count hits zero would close and reopen the physical
/// camera each time. Instead:
///
/// - count > 0: add the demand straight away and cancel any pending removal;
/// - count = 0: ask the owner to wait `grace`, then call `graceExpired(token:)`;
///   the demand is removed only if the count is still zero and no newer
///   removal has been scheduled since.
///
/// Pure value type: the owner supplies the clock and acts on the returned
/// actions.
struct VirtualCameraDemandGate: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        /// Add `.virtualCamera` to the capture pipeline.
        case addDemand
        /// Wait for the grace period, then call `graceExpired(token:)`.
        case scheduleRemoval(token: Int)
        /// Remove `.virtualCamera` from the capture pipeline.
        case removeDemand
    }

    private(set) var clients = 0
    private(set) var demanding = false
    private(set) var pendingToken: Int?
    private var lastToken = 0

    /// The client count changed, or became unknown (pass 0 when the device
    /// disappears, e.g. while the extension restarts).
    mutating func clientsChanged(to count: Int) -> Action {
        clients = max(0, count)
        if clients > 0 {
            pendingToken = nil
            if demanding { return .none }
            demanding = true
            return .addDemand
        }
        guard demanding, pendingToken == nil else { return .none }
        lastToken += 1
        pendingToken = lastToken
        return .scheduleRemoval(token: lastToken)
    }

    /// The grace period for `token` has elapsed.
    mutating func graceExpired(token: Int) -> Action {
        guard token == pendingToken else { return .none }
        pendingToken = nil
        guard clients == 0, demanding else { return .none }
        demanding = false
        return .removeDemand
    }
}
