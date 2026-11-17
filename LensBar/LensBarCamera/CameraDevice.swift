import CoreMedia
import CoreMediaIO
import Foundation
import IOKit.audio
import VirtualCameraKit

extension CMIOExtensionProperty {
    static let lensBarClientCount = CMIOExtensionProperty(
        rawValue: VirtualCameraProperty.clientCount.extensionPropertyName)
    static let lensBarFormat = CMIOExtensionProperty(
        rawValue: VirtualCameraProperty.format.extensionPropertyName)
}

/// The "LensBar Camera" device: a source stream clients read and a sink
/// stream the app writes into.
///
/// - Sink frames are forwarded to the source unchanged, whatever their size
///   and rate. That's how a resolution or FPS change in LensBar reaches a
///   client that is already streaming (PLAN.md §4.5).
/// - The advertised format changes only through `AdvertisedFormatState`, by
///   replacing the whole device (same device ID, fresh stream IDs) while no
///   client is streaming. Streams are never removed from a live device.
/// - While clients are streaming and the app isn't feeding the sink, the
///   source shows a placeholder frame.
/// - The streaming-client count is a custom property, pushed to listeners with
///   `notifyPropertiesChanged`.
///
/// Threading: CMIO calls in on its own queues. Mutable state is guarded by
/// `lock`, which is never held across a call into CMIO. Device replacement,
/// the placeholder timer and settle timers run on `workQueue`.
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    /// How long the client count must stay at zero before a deferred format
    /// change replaces the device. Zoom stops and restarts the source on every
    /// video toggle; this keeps the replacement out of those gaps.
    static let settleDelay: DispatchTimeInterval = .seconds(2)
    /// Placeholder frames are suppressed while sink frames are this recent.
    static let sinkFreshnessNs: UInt64 = 200_000_000
    /// Retry interval when the sink queue is empty.
    static let sinkPollInterval: DispatchTimeInterval = .milliseconds(5)

    private unowned let provider: CMIOExtensionProvider
    private let store: FormatStore
    private let workQueue = DispatchQueue(label: "com.lensbar.extension.device", qos: .userInteractive)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var _device: CMIOExtensionDevice!
    private var formatState: AdvertisedFormatState
    private var sourceStream: CameraStreamSource!
    private var sinkStream: CameraStreamSource!
    private var streamGeneration = 0
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var sinkSession = 0
    private var lastSinkFrameNs: UInt64 = 0
    private var placeholder: PlaceholderFrame?

    // Only touched on `workQueue`.
    private var placeholderTimer: DispatchSourceTimer?
    private var settleWork: DispatchWorkItem?

    var device: CMIOExtensionDevice { lock.withLock { _device } }

    init(provider: CMIOExtensionProvider, store: FormatStore) {
        self.provider = provider
        self.store = store
        let format = store.loadOrDefault()
        formatState = AdvertisedFormatState(advertised: format)
        super.init()
        buildDevice(format: format)
        extensionLog.info("device built, advertising \(format.encoded, privacy: .public)")
    }

    // MARK: Building

    /// Make a new device object with fresh source and sink streams advertising
    /// `format`. The caller adds it to the provider.
    private func buildDevice(format: VirtualCameraFormat) {
        let device = CMIOExtensionDevice(localizedName: VirtualCameraIdentity.deviceName,
                                         deviceID: UUID(uuidString: VirtualCameraIdentity.deviceUID)!,
                                         legacyDeviceID: nil, source: self)
        let duration = CMTime(value: format.frameDuration.value, timescale: format.frameDuration.timescale)
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: format.pixelFormat,
                                       width: format.width, height: format.height,
                                       extensions: nil, formatDescriptionOut: &desc)
        // Exactly one format with exactly one frame rate (PLAN.md §4.5).
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: desc!, maxFrameDuration: duration,
                                                     minFrameDuration: duration, validFrameDurations: nil)

        let generation = lock.withLock { () -> Int in
            streamGeneration += 1
            return streamGeneration
        }
        // A stream ID can't be reused once removed, so only the first build in
        // this process uses the well-known IDs. The app finds the sink by
        // direction, not ID.
        let first = generation == 1
        let source = CameraStreamSource(
            localizedName: "\(VirtualCameraIdentity.deviceName).Video",
            streamID: first ? UUID(uuidString: VirtualCameraIdentity.initialSourceStreamUID)! : UUID(),
            direction: .source, format: streamFormat, frameDuration: duration, generation: generation, owner: self)
        let sink = CameraStreamSource(
            localizedName: "\(VirtualCameraIdentity.deviceName).Sink",
            streamID: first ? UUID(uuidString: VirtualCameraIdentity.initialSinkStreamUID)! : UUID(),
            direction: .sink, format: streamFormat, frameDuration: duration, generation: generation, owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            extensionLog.error("addStream failed: \(error.localizedDescription, privacy: .public)")
        }
        let placeholder = PlaceholderFrame(format: format)
        if placeholder == nil {
            extensionLog.error("placeholder resources failed for \(format.encoded, privacy: .public)")
        }

        lock.withLock {
            _device = device
            sourceStream = source
            sinkStream = sink
            self.placeholder = placeholder
            sourceClients = 0
            sinkClient = nil
            sinkSession += 1
            lastSinkFrameNs = 0
        }
    }

    /// Swap in a new device that advertises `format`. Only called with zero
    /// streaming clients (`AdvertisedFormatState` guarantees it). Any sink
    /// session ends with the old device; the app re-finds the device by UID.
    private func replaceDevice(format: VirtualCameraFormat) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        stopPlaceholder()
        let old = device
        do {
            try provider.removeDevice(old)
        } catch {
            extensionLog.error("removeDevice failed: \(error.localizedDescription, privacy: .public)")
        }
        buildDevice(format: format)
        do {
            try provider.addDevice(device)
        } catch {
            extensionLog.error("addDevice failed: \(error.localizedDescription, privacy: .public)")
        }
        extensionLog.info("device replaced, advertising \(format.encoded, privacy: .public)")
    }

    private func perform(_ action: AdvertisedFormatState.Action) {
        switch action {
        case .none:
            break
        case .replaceDevice(let format):
            // Never rebuild inside a CMIO callback.
            workQueue.async { self.replaceDevice(format: format) }
        case .applyAfterSettling:
            workQueue.async { self.scheduleSettle() }
        }
    }

    private func scheduleSettle() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let action = self.lock.withLock { self.formatState.settled(clients: self.sourceClients) }
            if case .replaceDevice(let format) = action {
                self.replaceDevice(format: format)
            }
        }
        settleWork = work
        workQueue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    // MARK: Properties

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, .lensBarClientCount, .lensBarFormat]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { props.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { props.model = VirtualCameraIdentity.deviceName }
        let (clients, advertised) = lock.withLock { (sourceClients, formatState.advertised) }
        if properties.contains(.lensBarClientCount) {
            props.setPropertyState(CMIOExtensionPropertyState(value: ClientCountCodec.encode(clients) as NSString),
                                   forProperty: .lensBarClientCount)
        }
        if properties.contains(.lensBarFormat) {
            props.setPropertyState(CMIOExtensionPropertyState(value: advertised.encoded as NSString),
                                   forProperty: .lensBarFormat)
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        guard let state = deviceProperties.propertiesDictionary[.lensBarFormat] else { return }
        guard let string = state.value as? String, let format = VirtualCameraFormat(encoded: string) else {
            extensionLog.error("rejected format value \(String(describing: state.value), privacy: .public)")
            throw CameraExtensionError.invalidFormat(String(describing: state.value))
        }
        // Remember the latest request even if it can't be advertised yet, so
        // an extension restart comes back with LensBar's current settings.
        store.save(format)
        let (action, clients) = lock.withLock {
            (formatState.request(format, clients: sourceClients), sourceClients)
        }
        let outcome = String(describing: action)
        extensionLog.info(
            "format requested \(format.encoded, privacy: .public) clients=\(clients) -> \(outcome, privacy: .public)")
        perform(action)
    }

    private func notifyClientCount(_ clients: Int) {
        device.notifyPropertiesChanged([
            .lensBarClientCount: CMIOExtensionPropertyState(value: ClientCountCodec.encode(clients) as NSString),
        ])
    }

    // MARK: Source side

    func sourceStarted(generation: Int) {
        let clients: Int? = lock.withLock {
            guard generation == streamGeneration else { return nil }
            sourceClients += 1
            return sourceClients
        }
        guard let clients else { return }
        extensionLog.info("source started, clients=\(clients)")
        notifyClientCount(clients)
        perform(lock.withLock { formatState.clientsChanged(to: clients) })
        if clients == 1 { workQueue.async { self.startPlaceholder() } }
    }

    func sourceStopped(generation: Int) {
        let clients: Int? = lock.withLock {
            guard generation == streamGeneration else { return nil }
            sourceClients = max(0, sourceClients - 1)
            return sourceClients
        }
        guard let clients else { return }
        extensionLog.info("source stopped, clients=\(clients)")
        notifyClientCount(clients)
        if clients == 0 { workQueue.async { self.stopPlaceholder() } }
        perform(lock.withLock { formatState.clientsChanged(to: clients) })
    }

    // MARK: Placeholder

    private func startPlaceholder() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        stopPlaceholder()
        let (format, clients) = lock.withLock { (formatState.advertised, sourceClients) }
        guard clients > 0 else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: workQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / format.framesPerSecond, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.emitPlaceholder() }
        placeholderTimer = timer
        timer.resume()
    }

    private func stopPlaceholder() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        placeholderTimer?.cancel()
        placeholderTimer = nil
    }

    private func emitPlaceholder() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let (fresh, placeholder, stream) = lock.withLock {
            (now &- lastSinkFrameNs < Self.sinkFreshnessNs, self.placeholder, sourceStream?.stream)
        }
        guard !fresh, let placeholder, let stream else { return }
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        guard let buffer = placeholder.makeSampleBuffer(hostTime: hostTime) else { return }
        stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: Self.nanoseconds(hostTime))
    }

    // MARK: Sink side

    func sinkStarted(client: CMIOExtensionClient, generation: Int) {
        let session: Int? = lock.withLock {
            guard generation == streamGeneration else { return nil }
            sinkClient = client
            sinkSession += 1
            return sinkSession
        }
        guard let session else { return }
        extensionLog.info("sink started by pid=\(client.pid)")
        consumeNext(session: session)
    }

    func sinkStopped(generation: Int) {
        let stopped = lock.withLock { () -> Bool in
            guard generation == streamGeneration else { return false }
            sinkClient = nil
            sinkSession += 1
            return true
        }
        if stopped { extensionLog.info("sink stopped") }
    }

    /// Pull the next frame the app enqueued and forward it to the source.
    private func consumeNext(session: Int) {
        let (client, sink) = lock.withLock { () -> (CMIOExtensionClient?, CMIOExtensionStream?) in
            guard session == sinkSession else { return (nil, nil) }
            return (sinkClient, sinkStream?.stream)
        }
        guard let client, let sink else { return }

        sink.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, _ in
            guard let self else { return }
            guard let buffer else {
                // Nothing queued yet.
                self.workQueue.asyncAfter(deadline: .now() + Self.sinkPollInterval) {
                    self.consumeNext(session: session)
                }
                return
            }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let (current, streaming, source) = self.lock.withLock { () -> (Bool, Bool, CMIOExtensionStream?) in
                let current = session == self.sinkSession
                if current { self.lastSinkFrameNs = now }
                return (current, self.sourceClients > 0, self.sourceStream?.stream)
            }
            guard current else { return }
            // The app stamps frames on the host clock, so forward as-is.
            let hostNs = Self.nanoseconds(CMSampleBufferGetPresentationTimeStamp(buffer))
            if streaming, let source {
                source.send(buffer, discontinuity: [], hostTimeInNanoseconds: hostNs)
            }
            sink.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: hostNs))
            self.consumeNext(session: session)
        }
    }

    private static func nanoseconds(_ time: CMTime) -> UInt64 {
        guard time.isNumeric, time.seconds > 0 else { return 0 }
        return UInt64(time.seconds * Double(NSEC_PER_SEC))
    }
}
