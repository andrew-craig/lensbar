import SwiftUI
import AVFoundation
import AppKit

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?
    /// Called when a new (non-nil) session is attached to the preview layer.
    /// Attaching the layer resets the device's frame duration, so the view
    /// model uses this to re-assert the user's frame rate. See
    /// `PreviewNSView.session`.
    var onAttach: @MainActor @Sendable () -> Void = {}

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.onAttach = onAttach
        view.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.onAttach = onAttach
        nsView.session = session
    }
}

final class PreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    var onAttach: @MainActor @Sendable () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func makeBackingLayer() -> CALayer {
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        return previewLayer
    }

    var session: AVCaptureSession? {
        get { previewLayer.session }
        set {
            // Only react to an actual (re)attach — `updateNSView` re-sets the
            // same session on every SwiftUI update, and we must not fire the
            // callback (or re-trigger the frame-duration reset) for a no-op.
            guard previewLayer.session !== newValue else { return }
            previewLayer.session = newValue
            guard newValue != nil else { return }
            // The reset is synchronous with the assignment above; re-assert on
            // the next main-loop tick so we run after AVFoundation settles and
            // outside SwiftUI's view-update pass.
            DispatchQueue.main.async { [weak self] in self?.onAttach() }
        }
    }
}
