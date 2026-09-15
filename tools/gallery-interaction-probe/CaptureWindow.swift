// Standalone helper: captures only the GalleryProbe window, including its composited popover.
import AppKit
import ScreenCaptureKit
_ = NSApplication.shared
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let window = content.windows.first(where: { $0.title?.hasPrefix("Gallery Probe") == true }) else { fputs("No GalleryProbe window\n", stderr); exit(2) }
let config = SCStreamConfiguration()
config.width = Int(window.frame.width * 2)
config.height = Int(window.frame.height * 2)
let image: CGImage = try await withCheckedThrowingContinuation { continuation in
    SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) { image, error in
        if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error!) }
    }
}
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
