import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import VirtualCameraKit

/// The frame LensBar Camera shows while the app isn't feeding it: dark grey
/// with "Open LensBar" centred. Rendered once per format as an NV12 luma plane
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

    /// Video-range luma: 16 is black, 235 white. Text is drawn in a grey
    /// bitmap and scaled into that range.
    private static func renderLuma(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 0.16, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            drawCentred("LensBar Camera", size: CGFloat(height) / 12, gray: 0.9,
                        yOffset: CGFloat(height) / 20, in: ctx, width: width, height: height)
            drawCentred("Open LensBar to start the video", size: CGFloat(height) / 26, gray: 0.6,
                        yOffset: -CGFloat(height) / 20, in: ctx, width: width, height: height)
        }
        return pixels.map { UInt8(16 + (Int($0) * 219) / 255) }
    }

    private static func drawCentred(_ text: String, size: CGFloat, gray: CGFloat, yOffset: CGFloat,
                                    in ctx: CGContext, width: Int, height: Int) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let colour = CGColor(gray: gray, alpha: 1)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: colour] as CFDictionary
        guard let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        // A bitmap context stores its top row first, like the pixel buffer, so
        // no flip is needed. Origin is bottom-left; positive yOffset moves up.
        ctx.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                                   y: CGFloat(height) / 2 + yOffset - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, ctx)
    }
}
