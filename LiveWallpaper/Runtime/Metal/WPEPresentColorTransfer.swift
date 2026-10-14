#if !LITE_BUILD
/// The RGB values produced by the renderer, carried with the texture into present, span and capture.
enum WPEPresentColorTransfer: Equatable, Sendable {
    /// Authored WPE values still need terminal conversion to linear light.
    case authored
    /// The HDR post chain has already converted to linear light; preserve it, including values above one.
    case linear
}
#endif
