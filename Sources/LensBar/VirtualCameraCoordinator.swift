import Foundation
import os
import VirtualCameraKit

private let coordinatorLog = Logger(subsystem: "com.andrewcraig.LensBar", category: "VirtualCamera")

/// App-side plumbing for LensBar Camera (PLAN.md §6, Phase 3). Joins the
/// pieces that `CameraViewModel` shouldn't have to know about:
///
/// - `VirtualCameraMonitor` finds the device and reports its client count;
/// - `VirtualCameraDemandGate` turns the count into the `.virtualCamera`
///   capture demand, with a grace period so a client's quick stop/start
///   doesn't restart the physical camera;
/// - `VirtualCameraSink` receives every captured frame from `FrameTap` and is
///   attached exactly while a capture session is open and the device exists;
/// - format pushes from the view model go to the extension's `lbfm` property.
@MainActor
final class VirtualCameraCoordinator {
    /// How long capture keeps running after the last client leaves.
    static let grace: Duration = .seconds(5)

    struct Status: Equatable, Sendable {
        /// The LensBar Camera device is visible (installed, approved, running).
        var available = false
        /// Apps streaming LensBar Camera.
        var clients = 0
    }

    private(set) var status = Status()

    private let sink = VirtualCameraSink()
    private let monitor = VirtualCameraMonitor()
    private var gate = VirtualCameraDemandGate()
    private var started = false
    private var sessionOpen = false

    private let setDemand: (Bool) -> Void
    private let statusChanged: (Status) -> Void
    private let clientsArrived: () -> Void

    /// - Parameters:
    ///   - setDemand: add (`true`) or remove (`false`) the `.virtualCamera`
    ///     capture demand.
    ///   - statusChanged: availability or client count changed.
    ///   - clientsArrived: the client count went from zero to non-zero. Fires
    ///     even inside the grace period (when the demand never dropped), since
    ///     that is exactly when a client may have just come back from using the
    ///     physical camera directly and left it at its own frame rate.
    init(setDemand: @escaping (Bool) -> Void,
         statusChanged: @escaping (Status) -> Void,
         clientsArrived: @escaping () -> Void) {
        self.setDemand = setDemand
        self.statusChanged = statusChanged
        self.clientsArrived = clientsArrived
    }

    /// Begin watching the device and route `frameTap`'s frames to the sink.
    /// Idempotent.
    func start(frameTap: FrameTap) {
        guard !started else { return }
        started = true
        let sink = self.sink
        frameTap.setFrameHandler { sink.enqueue($0) }
        monitor.onEndpointChange = { [weak self] endpoint in
            guard let self else { return }
            updateSink()
            if endpoint == nil {
                // Extension gone (restart, upgrade, removal): the count is
                // unknown, so treat it as zero. The grace period covers a
                // quick restart, after which the real count is read again.
                clientsChanged(0)
            }
            publish()
        }
        monitor.onClientCountChange = { [weak self] count in
            self?.clientsChanged(count)
        }
        monitor.start()
    }

    /// Whether a capture session is open, i.e. frames can flow.
    func setSessionOpen(_ open: Bool) {
        sessionOpen = open
        updateSink()
    }

    /// LensBar's current output: active resolution, NV12 (what `FrameTap`
    /// delivers whatever the camera's native format) and the frame rate set
    /// on the device. The extension advertises it from its next zero-client
    /// moment (PLAN.md §4.5); frames at the new size and rate reach current
    /// clients regardless.
    func pushFormat(width: Int32, height: Int32, fps: Double) {
        guard started else { return }
        guard let format = VirtualCameraFormat(width: Int(width), height: Int(height), fps: fps) else {
            coordinatorLog.error("no virtual camera format for \(width)x\(height)@\(fps)")
            return
        }
        monitor.pushFormat(format)
    }

    // MARK: Private

    private func clientsChanged(_ count: Int) {
        let arrived = gate.clients == 0 && count > 0
        perform(gate.clientsChanged(to: count))
        if arrived {
            coordinatorLog.info("first client arrived: re-asserting camera settings")
            clientsArrived()
        }
        // Retries an attach that failed earlier; a no-op when already attached.
        updateSink()
        publish()
    }

    private func perform(_ action: VirtualCameraDemandGate.Action) {
        switch action {
        case .none:
            break
        case .addDemand:
            coordinatorLog.info("clients present: capture demanded")
            setDemand(true)
        case .removeDemand:
            coordinatorLog.info("no clients for the grace period: capture demand released")
            setDemand(false)
        case .scheduleRemoval(let token):
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.grace)
                guard let self else { return }
                perform(gate.graceExpired(token: token))
            }
        }
    }

    /// Feed the sink exactly while a session is open and the device exists.
    private func updateSink() {
        if sessionOpen, let endpoint = monitor.endpoint {
            sink.attach(to: endpoint)
        } else {
            sink.detach()
        }
    }

    private func publish() {
        let new = Status(available: monitor.endpoint != nil, clients: monitor.endpoint == nil ? 0 : gate.clients)
        guard new != status else { return }
        status = new
        statusChanged(new)
    }
}
