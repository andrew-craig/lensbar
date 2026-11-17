// Phase 0 spike harness (throwaway). Holds a physical camera at a fixed format
// and frame rate via AVCaptureSession + AVCaptureVideoDataOutput and logs the
// *measured* frame rate from presentation timestamps once per second. This is
// the oracle for the rest of the spike: the property can lie, the timestamps
// can't.
//
// Build:  swiftc -O -o build/spike-harness spike/harness/main.swift spike/harness/Sink.swift
// Run:    build/spike-harness [--device OBSBOT] [--fps 25] [--width 1280] [--height 720] [--sink UID]
//
// --sink UID also pushes every captured frame into that CMIO device's sink
// stream (the LensBarSpike camera extension), so clients of the virtual camera
// see the physical camera without ever opening it.
//
// It never re-asserts the frame rate after the initial set, so if another
// process resets the camera the drift shows up in the log (the watchdog
// approach is out of scope; we only want to observe).

import AVFoundation
import CoreMedia
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Args

struct Options {
    var device = "OBSBOT"
    var fps = 25.0
    var width: Int32 = 1280
    var height: Int32 = 720
    var sinkUID: String?
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--device": o.device = it.next() ?? o.device
        case "--fps": o.fps = Double(it.next() ?? "") ?? o.fps
        case "--width": o.width = Int32(it.next() ?? "") ?? o.width
        case "--height": o.height = Int32(it.next() ?? "") ?? o.height
        case "--sink": o.sinkUID = it.next()
        default:
            FileHandle.standardError.write("unknown arg \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

let opts = parseOptions()

let tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ s: String) { print("\(tsFormatter.string(from: Date())) \(s)") }

func fpsString(_ d: CMTime) -> String {
    d.seconds > 0 ? String(format: "%.2f", 1.0 / d.seconds) : "n/a"
}

// MARK: - Permission

// Camera TCC is attributed to the responsible process (the terminal app), so
// run this from a terminal that has, or can be granted, camera access.
let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
log("camera authorization: \(authStatus.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")
if authStatus == .notDetermined {
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { ok in
        log("requestAccess -> \(ok)")
        sem.signal()
    }
    sem.wait()
}
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    log("camera access not granted; enable it for this terminal in System Settings → Privacy & Security → Camera")
    exit(1)
}

// MARK: - Device + format

let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external, .builtInWideAngleCamera],
    mediaType: .video, position: .unspecified)
guard let device = discovery.devices.first(where: {
    $0.localizedName.localizedCaseInsensitiveContains(opts.device)
}) else {
    log("no device matching '\(opts.device)'. Available: \(discovery.devices.map(\.localizedName))")
    exit(1)
}
log("device: \(device.localizedName) uid=\(device.uniqueID)")

func subtype(_ f: AVCaptureDevice.Format) -> String {
    let s = CMFormatDescriptionGetMediaSubType(f.formatDescription)
    let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((s >> $0) & 0xff))) }
    return String(chars)
}

let candidates = device.formats.filter {
    let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
    return d.width == opts.width && d.height == opts.height &&
        $0.videoSupportedFrameRateRanges.contains { abs($0.maxFrameRate - opts.fps) <= 1.0 }
}
guard let format = candidates.first else {
    log("no \(opts.width)x\(opts.height) format offering \(opts.fps) fps")
    for f in device.formats {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let rates = f.videoSupportedFrameRateRanges.map { String(format: "%.0f", $0.maxFrameRate) }
        log("  \(d.width)x\(d.height) \(subtype(f)) [\(rates.joined(separator: ","))]")
    }
    exit(1)
}
let range = format.videoSupportedFrameRateRanges.min {
    abs($0.maxFrameRate - opts.fps) < abs($1.maxFrameRate - opts.fps)
}!
let targetDuration = range.minFrameDuration
log("format: \(opts.width)x\(opts.height) \(subtype(format)) target=\(fpsString(targetDuration)) fps")

// MARK: - Measurement

final class FrameCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var first: CMTime?
    private var last: CMTime?
    private var count = 0
    private var intervals = 0
    private var maxGap = 0.0
    private var latSum = 0.0
    var onFrame: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        // Delivery latency: host now minus PTS. For the virtual camera the PTS is the
        // sink enqueue time, so this is the added latency through the extension.
        let lat = (CMClockGetTime(CMClockGetHostTimeClock()) - pts).seconds
        lock.lock(); defer { lock.unlock() }
        latSum += lat
        if let l = last { maxGap = max(maxGap, (pts - l).seconds); intervals += 1 }
        if first == nil { first = pts }
        last = pts
        count += 1
        lock.unlock()
        onFrame?(sb)
        lock.lock()
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sb: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        log("dropped frame")
    }

    /// Returns (fps measured over the window, frames, max inter-frame gap ms, mean latency ms) and resets.
    func drain() -> (Double, Int, Double, Double) {
        lock.lock(); defer { lock.unlock() }
        defer { first = last; count = 0; intervals = 0; maxGap = 0; latSum = 0 }
        let lat = count > 0 ? latSum / Double(count) * 1000 : 0
        guard let f = first, let l = last, intervals > 0 else { return (0, count, 0, lat) }
        let fps = Double(intervals) / (l - f).seconds
        return (fps, count, maxGap * 1000, lat)
    }
}

let counter = FrameCounter()
let session = AVCaptureSession()
let queue = DispatchQueue(label: "frames")

do {
    let input = try AVCaptureDeviceInput(device: device)
    session.beginConfiguration()
    guard session.canAddInput(input) else { log("cannot add input"); exit(1) }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    output.setSampleBufferDelegate(counter, queue: queue)
    guard session.canAddOutput(output) else { log("cannot add output"); exit(1) }
    session.addOutput(output)
    session.commitConfiguration()
} catch {
    log("input error: \(error)")
    exit(1)
}

func applyFormatAndRate(_ why: String) {
    do {
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = targetDuration
        device.activeVideoMaxFrameDuration = targetDuration
        device.unlockForConfiguration()
        log("applied format + \(fpsString(targetDuration)) fps (\(why))")
    } catch {
        log("lockForConfiguration failed (\(why)): \(error)")
    }
}

// Frame-duration writes before startRunning() are discarded (UVC renegotiates
// at the format default), so set the format pre-start and the rate post-start.
applyFormatAndRate("pre-start")
session.startRunning()
applyFormatAndRate("post-start")

// MARK: - Optional sink feed

var sink: SinkFeeder?
if let uid = opts.sinkUID {
    guard let s = SinkFeeder(deviceUID: uid) else { exit(1) }
    sink = s
    counter.onFrame = { s.enqueue($0) }
}

// MARK: - Observe external changes (report only, never correct)

var observations: [NSKeyValueObservation] = []
observations.append(device.observe(\.activeVideoMinFrameDuration, options: [.old, .new]) { _, c in
    log("KVO activeVideoMinFrameDuration \(fpsString(c.oldValue ?? .invalid)) -> \(fpsString(c.newValue ?? .invalid)) fps")
})
observations.append(device.observe(\.activeFormat, options: [.new]) { d, _ in
    let dim = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
    log("KVO activeFormat -> \(dim.width)x\(dim.height) \(subtype(d.activeFormat))")
})
observations.append(device.observe(\.isInUseByAnotherApplication, options: [.new]) { d, _ in
    log("KVO isInUseByAnotherApplication -> \(d.isInUseByAnotherApplication)")
})
NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                       object: session, queue: nil) { n in
    log("session interrupted \(n.userInfo ?? [:])")
}
NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                       object: session, queue: nil) { _ in
    log("session interruption ended")
}
NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                       object: session, queue: nil) { n in
    log("session runtime error \(n.userInfo ?? [:])")
}

// MARK: - Report loop

let target = 1.0 / targetDuration.seconds
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    let (fps, n, gap, lat) = counter.drain()
    let flag = abs(fps - target) > 1.0 ? "  <-- OFF TARGET" : ""
    var sinkInfo = ""
    if let s = sink {
        let (enq, drop) = s.drainStats()
        sinkInfo = " sink enq=\(enq) drop=\(drop)"
    }
    log(String(format: "measured=%.2f fps frames=%d maxgap=%.1fms lat=%.1fms property=%@ fps inUseByOther=%@%@%@",
               fps, n, gap, lat, fpsString(device.activeVideoMinFrameDuration),
               device.isInUseByAnotherApplication ? "yes" : "no", sinkInfo, flag))
}
timer.resume()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    log("stopping")
    sink?.stop()
    session.stopRunning()
    exit(0)
}
sigint.resume()

dispatchMain()
