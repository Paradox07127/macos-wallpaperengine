import Foundation

/// The two system texture names the installed corpus actually declares. Any
/// other `type: "system"` name stays unhandled and falls through to the
/// authored placeholder.
public enum WPEMediaSystemTexture: Sendable, Equatable, CaseIterable {
    case thumbnail
    case previousThumbnail

    /// Case-insensitive, matching how every other authored name resolves in this renderer.
    /// Matched on the name alone: the `$` prefix is itself WPE's engine-provided marker, and
    /// gating on `type == "system"` would drop the older bare-string form for no benefit — no
    /// author names a texture `$mediaThumbnail`.
    public init?(bindingName: String) {
        switch bindingName.lowercased() {
        case "$mediathumbnail": self = .thumbnail
        case "$mediapreviousthumbnail": self = .previousThumbnail
        default: return nil
        }
    }
}
