import AppKit

/// Whether wallpaper-owned windows may be read by screen capture — screenshots, screen recording,
/// and meeting screen-share all go through the same AppKit flag. The policy lives here instead of in
/// each window's initializer signature because wallpaper windows are built from several call sites
/// (video, HTML, scene, ambient, and the Monitor overlay); a new call site inherits the user's
/// choice rather than silently defaulting to the wrong one. The app layer owns writing it from
/// `GlobalSettings`.
@MainActor
public enum WallpaperCapturePolicy {
    /// Default matches the shipping default: the wallpaper is capturable.
    public static var allowsScreenCapture = true

    public static var windowSharingType: NSWindow.SharingType {
        allowsScreenCapture ? .readOnly : .none
    }
}
