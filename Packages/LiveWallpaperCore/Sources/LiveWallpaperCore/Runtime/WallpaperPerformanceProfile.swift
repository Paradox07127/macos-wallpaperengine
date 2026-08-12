import Foundation

/// Uniform render profile. No graduated thermal steps — pressure → pause;
/// per-screen FPS caps stay user-owned (`.quality` / `.suspended`).
public enum WallpaperPerformanceProfile: Equatable, Sendable {
    case quality
    case suspended
}
