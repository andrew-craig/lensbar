import SwiftUI
import AVFoundation
import AppKit

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.session = session
    }
}

final class PreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

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
        set { previewLayer.session = newValue }
    }
}
