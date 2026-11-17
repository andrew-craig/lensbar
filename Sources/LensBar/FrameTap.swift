@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import os

/// Taps the capture session's video frames with an `AVCaptureVideoDataOutput`.
///
/// Frames arrive as NV12 (`420YpCbCr8BiPlanarVideoRange`), IOSurface-backed
/// pixel buffers, which is what the virtual camera's sink stream will take
/// without a copy (Phase 3). Every frame's timestamp feeds the `RateMonitor`,
/// including frames AVFoundation drops for being late, so the measured rate
/// reflects the sensor rather than how fast this process consumes frames.
///
/// One `FrameTap` lives for the app's lifetime; a fresh output is made for each
/// session because an `AVCaptureOutput` can belong to only one session.
///
/// Attaching the output is a session reconfiguration point that resets the
/// device's frame duration, like `startRunning()` and preview-layer attach.
/// `AVFoundationController.openSession` adds it before `startRunning()` so the
/// post-start frame-rate write re-asserts the rate after it.
final class FrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    typealias FrameHandler = @Sendable (CMSampleBuffer) -> Void

    let rateMonitor: RateMonitor
    private let queue = DispatchQueue(label: "com.lensbar.frametap", qos: .userInteractive)
    private let handler = OSAllocatedUnfairLock<FrameHandler?>(initialState: nil)

    init(rateMonitor: RateMonitor) {
        self.rateMonitor = rateMonitor
        super.init()
    }

    /// Install (or clear) the per-frame consumer. Called on the capture queue,
    /// so it must be cheap and must not block. Phase 3's `VirtualCameraSink`
    /// hooks in here.
    func setFrameHandler(_ newHandler: FrameHandler?) {
        handler.withLock { $0 = newHandler }
    }

    /// Make a new video data output with this tap as its delegate.
    func makeOutput() -> AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        return output
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        rateMonitor.record(presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        handler.withLock { $0 }?(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // A dropped frame was still produced by the sensor; count it so the
        // reported rate isn't depressed by our own consumer being slow.
        rateMonitor.record(presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
