import AppKit

/// Whether wallpaper-owned windows may be read by screen capture — screenshots,
/// recording and screen-share all go through this one AppKit flag.
@MainActor
public enum WallpaperCapturePolicy {
    /// Default matches the shipping default: the wallpaper is capturable.
    public static var allowsScreenCapture = true

    public static var windowSharingType: NSWindow.SharingType {
        allowsScreenCapture ? .readOnly : .none
    }
}
