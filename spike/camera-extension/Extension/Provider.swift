// Phase 0 spike camera extension (throwaway).
//
// One device, "LensBarSpike Camera", with:
//   - a source stream (what Zoom reads), one NV12 format, one frame rate;
//   - a sink stream the host app / harness pushes frames into.
// While a sink client is feeding, sink frames are forwarded to the source.
// Otherwise the source emits a moving placeholder so it's visibly alive.
//
// Custom device properties (CMIO selector = the 4cc, global scope, element 0):
//   'lbcc'  read-only String: number of running source-stream clients (task_9413).
//           Changes are pushed with notifyPropertiesChanged.
//   'lbfm'  read/write String "WxH@fps:mode" (task_c735). Sets the advertised
//           format. mode = none   → keep the advertised format, only change the
//                                   placeholder (frames from the sink pass through
//                                   whatever size/rate they are)
//                          stream → remove + re-add both streams with the new format
//                          device → remove + re-add the whole device

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os

let spikeLog = Logger(subsystem: "com.andrewcraig.LensBarSpike", category: "extension")

enum SpikeIDs {
    // Fixed so the app/harness can find the device and streams by UID.
    static let device = UUID(uuidString: "6A1B6C2E-8F0E-4B7A-9C55-2B1D3E4F5A60")!
    static let source = UUID(uuidString: "6A1B6C2E-8F0E-4B7A-9C55-2B1D3E4F5A61")!
    static let sink = UUID(uuidString: "6A1B6C2E-8F0E-4B7A-9C55-2B1D3E4F5A62")!
}

extension CMIOExtensionProperty {
    static let clientCount = CMIOExtensionProperty(rawValue: "4cc_lbcc_glob_0000")
    static let formatSpec = CMIOExtensionProperty(rawValue: "4cc_lbfm_glob_0000")
}

struct SpikeFormat: Equatable, CustomStringConvertible {
    var width: Int32 = 1280
    var height: Int32 = 720
    var fps: Int32 = 25
    var description: String { "\(width)x\(height)@\(fps)" }

    /// Parses "WxH@fps:mode".
    static func parse(_ s: String) -> (SpikeFormat, String)? {
        let parts = s.split(separator: ":")
        let fmt = parts[0].split(whereSeparator: { $0 == "x" || $0 == "@" })
        guard fmt.count == 3, let w = Int32(fmt[0]), let h = Int32(fmt[1]), let f = Int32(fmt[2]) else { return nil }
        return (SpikeFormat(width: w, height: h, fps: f), parts.count > 1 ? String(parts[1]) : "none")
    }
}

// MARK: - Provider

final class SpikeProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: SpikeDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = SpikeDeviceSource(localizedName: "LensBarSpike Camera", provider: provider)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("addDevice failed: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        spikeLog.info("client connected pid=\(client.pid) signingID=\(client.signingID ?? "?", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        spikeLog.info("client disconnected pid=\(client.pid)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "LensBar (spike)" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class SpikeDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private unowned let provider: CMIOExtensionProvider
    private let localizedName: String
    private var sourceStream: SpikeStreamSource!
    private var sinkStream: SpikeStreamSource!

    // Format state, guarded by `lock`.
    private var advertised = SpikeFormat()
    private var placeholderFormat = SpikeFormat()
    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private let bufferAuxAttributes: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: 5]

    private let timerQueue = DispatchQueue(label: "spike.placeholder", qos: .userInteractive)
    private var placeholderTimer: DispatchSourceTimer?
    private var placeholderPhase = 0

    private let lock = NSRecursiveLock()
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var sinkFeeding = false
    private var sinkGeneration = 0
    private var lastSinkFrameHostNs: UInt64 = 0
    private var streamGeneration = 0

    init(localizedName: String, provider: CMIOExtensionProvider) {
        self.provider = provider
        self.localizedName = localizedName
        super.init()
        buildDevice()
        rebuildPlaceholderResources(placeholderFormat)
    }

    private func buildDevice() {
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: SpikeIDs.device,
                                     legacyDeviceID: nil, source: self)
        buildStreams()
    }

    /// Creates source + sink streams for the advertised format and adds them to `device`.
    private func buildStreams() {
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       width: advertised.width, height: advertised.height,
                                       extensions: nil, formatDescriptionOut: &desc)
        // Exactly one format with exactly one frame rate (PLAN.md §4.5).
        let frameDuration = CMTime(value: 1, timescale: advertised.fps)
        let format = CMIOExtensionStreamFormat(formatDescription: desc!,
                                               maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration,
                                               validFrameDurations: nil)
        // A removed stream's ID can't be re-added to the same device, so later
        // generations get fresh IDs (the feeder finds the sink by direction).
        let first = streamGeneration == 0
        streamGeneration += 1
        sourceStream = SpikeStreamSource(localizedName: "LensBarSpike.Video", streamID: first ? SpikeIDs.source : UUID(),
                                         format: format, fps: advertised.fps, direction: .source, owner: self)
        sinkStream = SpikeStreamSource(localizedName: "LensBarSpike.Sink", streamID: first ? SpikeIDs.sink : UUID(),
                                       format: format, fps: advertised.fps, direction: .sink, owner: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            spikeLog.error("addStream failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rebuildPlaceholderResources(_ f: SpikeFormat) {
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       width: f.width, height: f.height, extensions: nil, formatDescriptionOut: &desc)
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: f.width,
            kCVPixelBufferHeightKey: f.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)
        lock.lock()
        videoDescription = desc
        bufferPool = pool
        placeholderFormat = f
        placeholderPhase = 0
        lock.unlock()
    }

    // MARK: Properties

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, .clientCount, .formatSpec]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "LensBarSpike Camera" }
        lock.lock()
        let n = sourceClients
        let fmt = advertised.description
        lock.unlock()
        if properties.contains(.clientCount) {
            p.setPropertyState(CMIOExtensionPropertyState(value: "\(n)" as NSString), forProperty: .clientCount)
        }
        if properties.contains(.formatSpec) {
            p.setPropertyState(CMIOExtensionPropertyState(value: fmt as NSString), forProperty: .formatSpec)
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        guard let state = deviceProperties.propertiesDictionary[.formatSpec],
              let s = state.value as? String else { return }
        guard let (fmt, mode) = SpikeFormat.parse(s) else {
            spikeLog.error("bad lbfm value '\(s, privacy: .public)'")
            return
        }
        spikeLog.info("lbfm set: \(fmt.description, privacy: .public) mode=\(mode, privacy: .public)")
        // Don't rebuild streams/devices inside the property callback.
        timerQueue.async { self.applyFormat(fmt, mode: mode) }
    }

    private func notifyClientCount() {
        lock.lock(); let n = sourceClients; lock.unlock()
        device.notifyPropertiesChanged([.clientCount: CMIOExtensionPropertyState(value: "\(n)" as NSString as AnyObject)])
    }

    // MARK: Format switching (task_c735)

    private func applyFormat(_ fmt: SpikeFormat, mode: String) {
        rebuildPlaceholderResources(fmt)
        switch mode {
        case "none":
            spikeLog.info("format: placeholder now \(fmt.description, privacy: .public), advertised unchanged")
        case "stream":
            lock.lock()
            let wasRunning = sourceClients > 0
            advertised = fmt
            lock.unlock()
            stopPlaceholder()
            resetStreamState()
            do {
                try device.removeStream(sourceStream.stream)
                try device.removeStream(sinkStream.stream)
            } catch {
                spikeLog.error("removeStream failed: \(error.localizedDescription, privacy: .public)")
            }
            buildStreams()
            spikeLog.info("format: streams replaced with \(fmt.description, privacy: .public) (source was running: \(wasRunning))")
        case "device":
            lock.lock()
            advertised = fmt
            lock.unlock()
            stopPlaceholder()
            resetStreamState()
            do {
                try provider.removeDevice(device)
            } catch {
                spikeLog.error("removeDevice failed: \(error.localizedDescription, privacy: .public)")
            }
            buildDevice()
            do {
                try provider.addDevice(device)
            } catch {
                spikeLog.error("addDevice failed: \(error.localizedDescription, privacy: .public)")
            }
            spikeLog.info("format: device replaced with \(fmt.description, privacy: .public)")
        default:
            spikeLog.error("unknown mode \(mode, privacy: .public)")
            return
        }
        device.notifyPropertiesChanged([.formatSpec: CMIOExtensionPropertyState(value: fmt.description as NSString as AnyObject)])
    }

    /// Old streams are gone; forget their clients so the new ones start clean.
    private func resetStreamState() {
        lock.lock()
        sourceClients = 0
        sinkFeeding = false
        sinkClient = nil
        sinkGeneration += 1
        lock.unlock()
    }

    // MARK: Source side

    func sourceStarted() {
        lock.lock()
        sourceClients += 1
        let n = sourceClients
        lock.unlock()
        spikeLog.info("source stream started, clients=\(n)")
        notifyClientCount()
        if n == 1 { startPlaceholder() }
    }

    func sourceStopped() {
        lock.lock()
        sourceClients = max(0, sourceClients - 1)
        let n = sourceClients
        lock.unlock()
        spikeLog.info("source stream stopped, clients=\(n)")
        notifyClientCount()
        if n == 0 { stopPlaceholder() }
    }

    /// Placeholder generator. Ticks at the placeholder rate; skips its frame
    /// whenever the sink delivered one recently so sink frames win.
    private func startPlaceholder() {
        stopPlaceholder()
        lock.lock(); let fps = placeholderFormat.fps; lock.unlock()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .seconds(0))
        t.setEventHandler { [weak self] in self?.emitPlaceholder() }
        placeholderTimer = t
        t.resume()
    }

    private func stopPlaceholder() {
        placeholderTimer?.cancel()
        placeholderTimer = nil
    }

    private func emitPlaceholder() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lock.lock()
        let sinkRecent = now &- lastSinkFrameHostNs < 200_000_000
        let pool = bufferPool!
        let desc = videoDescription!
        let fps = placeholderFormat.fps
        let stream: CMIOExtensionStream = sourceStream.stream
        lock.unlock()
        if sinkRecent { return }

        var pb: CVPixelBuffer?
        let err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                                                                     bufferAuxAttributes, &pb)
        guard err == kCVReturnSuccess, let pixelBuffer = pb else { return }
        drawPlaceholder(pixelBuffer)

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                                 formatDescription: desc, sampleTiming: &timing,
                                                 sampleBufferOut: &sb) == noErr, let sampleBuffer = sb
        else { return }
        stream.send(sampleBuffer, discontinuity: [],
                    hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }

    /// Dark-grey frame with a bright vertical bar sweeping across it.
    private func drawPlaceholder(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let barW = w / 16
        placeholderPhase = (placeholderPhase + 8) % w
        for row in 0..<h {
            let line = y + row * yStride
            memset(line, 40, w)
            let start = placeholderPhase
            let end = min(w, start + barW)
            memset(line + start, 200, end - start)
        }
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        memset(uv, 128, uvStride * CVPixelBufferGetHeightOfPlane(pb, 1))
    }

    // MARK: Sink side

    func sinkStarted(client: CMIOExtensionClient) {
        lock.lock()
        sinkClient = client
        sinkFeeding = true
        sinkGeneration += 1
        let gen = sinkGeneration
        lock.unlock()
        spikeLog.info("sink stream started by pid=\(client.pid)")
        consumeNext(gen)
    }

    func sinkStopped() {
        lock.lock()
        sinkFeeding = false
        sinkClient = nil
        lock.unlock()
        spikeLog.info("sink stream stopped")
    }

    private func consumeNext(_ gen: Int) {
        lock.lock()
        let client = sinkClient
        let feeding = sinkFeeding && gen == sinkGeneration
        let sink: CMIOExtensionStream = sinkStream.stream
        lock.unlock()
        guard feeding, let client else { return }

        sink.consumeSampleBuffer(from: client) { [weak self] sbuf, seq, _, _, err in
            guard let self else { return }
            if let sbuf {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self.lock.lock()
                self.lastSinkFrameHostNs = now
                let haveClients = self.sourceClients > 0
                let source: CMIOExtensionStream = self.sourceStream.stream
                self.lock.unlock()
                let ptsNs = UInt64(CMSampleBufferGetPresentationTimeStamp(sbuf).seconds * Double(NSEC_PER_SEC))
                if haveClients {
                    // Forward as-is; the feeder stamps frames on the host clock.
                    source.send(sbuf, discontinuity: [], hostTimeInNanoseconds: ptsNs)
                }
                sink.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: seq,
                                                                               hostTimeInNanoseconds: ptsNs))
                self.consumeNext(gen)
            } else {
                if let err { spikeLog.debug("consumeSampleBuffer: \(err.localizedDescription, privacy: .public)") }
                // Nothing queued yet; poll again shortly.
                self.timerQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consumeNext(gen) }
            }
        }
    }
}

// MARK: - Stream

final class SpikeStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let fps: Int32
    private let direction: CMIOExtensionStream.Direction
    private unowned let owner: SpikeDeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, fps: Int32,
         direction: CMIOExtensionStream.Direction, owner: SpikeDeviceSource) {
        self.format = format
        self.fps = fps
        self.direction = direction
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        var p: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            p.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                         .streamSinkBufferUnderrunCount, .streamSinkEndOfData])
        }
        return p
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: fps) }
        if direction == .sink {
            if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 4 }
            if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        switch direction {
        case .source: owner.sourceStarted()
        case .sink:
            guard let client else { throw NSError(domain: "spike", code: 1) }
            owner.sinkStarted(client: client)
        @unknown default: break
        }
    }

    func stopStream() throws {
        switch direction {
        case .source: owner.sourceStopped()
        case .sink: owner.sinkStopped()
        @unknown default: break
        }
    }
}
