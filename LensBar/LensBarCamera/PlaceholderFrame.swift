import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VirtualCameraKit

/// The frame LensBar Camera shows while the app isn't feeding it: black with
/// the LensBar mark in the top-left corner. Rendered once per format as an NV12 luma plane
/// (chroma is neutral grey), then copied into a pooled pixel buffer per frame.
struct PlaceholderFrame {
    let format: VirtualCameraFormat
    let formatDescription: CMFormatDescription
    private let pool: CVPixelBufferPool
    private let luma: [UInt8]
    private static var poolAux: CFDictionary { [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary }

    init?(format: VirtualCameraFormat) {
        let width = Int(format.width), height = Int(format.height)
        var desc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: format.pixelFormat,
                                             width: format.width, height: format.height,
                                             extensions: nil, formatDescriptionOut: &desc) == noErr,
              let desc else { return nil }
        let attrs = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ] as CFDictionary
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool) == kCVReturnSuccess,
              let pool else { return nil }
        self.format = format
        self.formatDescription = desc
        self.pool = pool
        self.luma = Self.renderLuma(width: width, height: height)
    }

    /// A new sample buffer stamped `hostTime`, or nil if the pool is exhausted.
    func makeSampleBuffer(hostTime: CMTime) -> CMSampleBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, Self.poolAux, &pb)
                == kCVReturnSuccess, let pixelBuffer = pb else { return nil }
        fill(pixelBuffer)
        let duration = CMTime(value: format.frameDuration.value, timescale: format.frameDuration.timescale)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: hostTime, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                                 formatDescription: formatDescription, sampleTiming: &timing,
                                                 sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    private func fill(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let width = CVPixelBufferGetWidthOfPlane(pb, 0)
        let height = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) {
            luma.withUnsafeBufferPointer { src in
                for row in 0..<height {
                    memcpy(y + row * yStride, src.baseAddress! + row * width, width)
                }
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
        }
    }

    /// Video-range luma: 16 is black, 235 white. The icon is drawn in a grey
    /// bitmap and scaled into that range.
    private static func renderLuma(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let iconSize = CGFloat(height) / 9
            let margin = CGFloat(height) / 24
            drawIcon(in: ctx, rect: CGRect(x: margin, y: CGFloat(height) - margin - iconSize,
                                           width: iconSize, height: iconSize), gray: 0.85)
        }
        return pixels.map { UInt8(16 + (Int($0) * 219) / 255) }
    }

    /// The LensBar mark (Lensbar.svg: a ring with a dot up and to the right),
    /// fitted to `rect`. The SVG's visible extent is 34 units (ring radius 15
    /// plus half the 4-unit stroke, either side of centre 22). A bitmap context
    /// stores its top row first, like the pixel buffer, so no flip is needed;
    /// origin is bottom-left, so the dot's SVG y (down) is negated.
    private static func drawIcon(in ctx: CGContext, rect: CGRect, gray: CGFloat) {
        let s = rect.width / 34
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        ctx.setStrokeColor(gray: gray, alpha: 1)
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.setLineWidth(4 * s)
        ctx.strokeEllipse(in: CGRect(x: centre.x - 15 * s, y: centre.y - 15 * s, width: 30 * s, height: 30 * s))
        let dot = CGPoint(x: centre.x + 4.5 * s, y: centre.y + 2.5 * s)
        ctx.fillEllipse(in: CGRect(x: dot.x - 4.5 * s, y: dot.y - 4.5 * s, width: 9 * s, height: 9 * s))
    }
}
