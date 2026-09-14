import Foundation

/// The two system texture names the installed corpus actually declares. Any
/// other `type: "system"` name stays unhandled and falls through to the
/// authored placeholder.
public enum WPEMediaSystemTexture: Sendable, Equatable, CaseIterable {
    case thumbnail
    case previousThumbnail

    /// Matched on the name alone, case-insensitively: gating on `type == "system"` would drop
    /// the older bare-string form, and the `$` prefix is itself WPE's engine-provided marker.
    public init?(bindingName: String) {
        switch bindingName.lowercased() {
        case "$mediathumbnail": self = .thumbnail
        case "$mediapreviousthumbnail": self = .previousThumbnail
        default: return nil
        }
    }
}
