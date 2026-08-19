import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
@preconcurrency import IOSurface
import QuartzCore

/// Builds IOSurface-backed sample buffers for the seed still. Plain
/// CALayer.contents is black across the remote context boundary, so even a
/// flat colour has to arrive as a sample (contract §5).
enum StillFrameFactory {
    /// Seed from the video's own poster frame. The upstream reference keeps a
    /// BMP cache of the first frame for exactly this moment; we already have a
    /// JPEG next to the video (the app writes it at publish time), so decoding
    /// that is the same idea without a second cache — and without running an
    /// AVAssetImageGenerator inside the appex, which starves the playback
    /// decoder (contract §5).
    static func makeSampleBuffer(imageURL: URL, size: CGSize) -> CMSampleBuffer? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return makeSampleBuffer(size: size) { context, width, height in
            // Fill first: the poster is 16:9 and the display may not be, and an
            // unpainted margin would show the uninitialised surface again.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let drawWidth = CGFloat(image.width) * scale
            let drawHeight = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(
                x: (CGFloat(width) - drawWidth) / 2,
                y: (CGFloat(height) - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            ))
        }
    }

    static func makeSampleBuffer(color: CGColor, size: CGSize) -> CMSampleBuffer? {
        makeSampleBuffer(size: size) { context, width, height in
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Shared plumbing: an IOSurface-backed BGRA buffer the caller paints into,
    /// wrapped as a display-immediately sample.
    private static func makeSampleBuffer(
        size: CGSize,
        draw: (CGContext, Int, Int) -> Void
    ) -> CMSampleBuffer? {
        let width = max(2, Int(size.width))
        let height = max(2, Int(size.height))
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer),
           let context = CGContext(
               data: base,
               width: width,
               height: height,
               bitsPerComponent: 8,
               bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
               space: CGColorSpaceCreateDeviceRGB(),
               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
           ) {
            draw(context, width, height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription) == noErr,
            let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}

/// The wallpaper panel's own preview asks for a snapshot; returning nil leaves
/// that preview empty. Upstream renders a fresh frame with an
/// AVAssetImageGenerator, but the appex's decoder budget is exactly what must
/// not be spent here (contract §5), and the app already wrote a poster JPEG
/// next to every published video.
enum SnapshotFactory {
    static func makeIOSurface(imageURL: URL) -> IOSurface? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        let properties: [IOSurfacePropertyKey: any Sendable] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241, // 'BGRA'
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }

        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return surface
    }
}
