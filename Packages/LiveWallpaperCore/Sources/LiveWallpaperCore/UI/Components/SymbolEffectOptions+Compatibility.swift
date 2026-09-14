import SwiftUI

public extension SymbolEffectOptions {
    /// Smoothest available repeat cadence: macOS 14 has no continuous variant, so it
    /// falls back to the periodic `.repeating`.
    static var continuouslyRepeating: SymbolEffectOptions {
        if #available(macOS 15.0, *) {
            return .repeat(.continuous)
        } else {
            return .repeating
        }
    }
}
