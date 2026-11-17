import Foundation

/// Decides when the extension may change the format it advertises
/// (PLAN.md §4.5, revised after the spike).
///
/// A client that is streaming must keep seeing the same advertised format:
/// replacing streams or the device under Zoom froze it or switched its video
/// off. Frames at a new size or rate flow through the unchanged format fine.
/// So a requested format is applied, by replacing the device, only while the
/// source has zero clients; otherwise it waits until the count reaches zero.
///
/// Zoom stops and restarts the source stream on every video toggle and camera
/// switch, so "zero clients" is often a gap of a fraction of a second. The
/// extension therefore applies a deferred change only after the count has
/// stayed at zero for a settle delay: `clientsChanged` returns
/// `.applyAfterSettling`, and the extension calls `settled` when the delay
/// expires. An immediate request at zero clients is applied straight away,
/// since nothing is streaming then.
///
/// Pure value type: the extension owns the clock and the device.
public struct AdvertisedFormatState: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Nothing to do.
        case none
        /// Replace the device now so it advertises this format.
        case replaceDevice(VirtualCameraFormat)
        /// Count just reached zero with a change pending. Wait for the settle
        /// delay, then call `settled(clients:)`.
        case applyAfterSettling
    }

    /// Format the device currently advertises.
    public private(set) var advertised: VirtualCameraFormat
    /// Format requested while clients were streaming, waiting for zero clients.
    public private(set) var pending: VirtualCameraFormat?

    public init(advertised: VirtualCameraFormat) {
        self.advertised = advertised
    }

    /// The app pushed a format.
    public mutating func request(_ format: VirtualCameraFormat, clients: Int) -> Action {
        if format == advertised {
            // Back to what's advertised: drop any pending change.
            pending = nil
            return .none
        }
        if clients > 0 {
            pending = format
            return .none
        }
        return commit(format)
    }

    /// The source-stream client count changed.
    public mutating func clientsChanged(to clients: Int) -> Action {
        clients == 0 && pending != nil ? .applyAfterSettling : .none
    }

    /// The settle delay after reaching zero clients expired.
    public mutating func settled(clients: Int) -> Action {
        guard clients == 0, let pending else { return .none }
        return commit(pending)
    }

    private mutating func commit(_ format: VirtualCameraFormat) -> Action {
        advertised = format
        pending = nil
        return .replaceDevice(format)
    }
}
