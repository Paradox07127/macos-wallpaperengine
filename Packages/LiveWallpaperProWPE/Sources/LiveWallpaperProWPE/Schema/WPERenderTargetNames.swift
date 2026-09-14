import Foundation

public enum WPERenderTargetNames {

    /// `_rt_imageLayerComposite_<objectID>_{a,b}` / `_rt_createdLayerComposite_<key>_{a,b}` pair.
    public struct CompositePair: Equatable, Sendable {
        public let a: String
        public let b: String
    }

    /// `_rt_puppetClip_<objectID>` — puppet clip-mask RT injected by the graph
    /// builder (slot 8) and detected by the executor with exact-equality.
    public enum PuppetClip {
        private static let prefix = "_rt_puppetClip_"
        private static let deferredPrefix = "_rt_puppetClipScene_"
        /// Renderer-internal texture slots used only to retain/load every authored clip-group mask.
        /// They sit outside WPE's shader sampler range, so they cannot shadow authored bindings.
        private static let maskBindingBaseSlot = 64

        public static func make(objectID: String) -> String { "\(prefix)\(objectID)" }

        public static func maskBindingSlot(groupIndex: Int) -> Int {
            maskBindingBaseSlot + max(groupIndex, 0)
        }

        public static func isMaskBindingSlot(_ slot: Int) -> Bool {
            slot >= maskBindingBaseSlot
        }

        /// index == 0 is the base name; index > 0 is `<base>_s<index>`. Takes the caller's existing `base` verbatim.
        public static func makeSource(base: String, index: Int) -> String {
            index == 0 ? base : "\(base)_s\(index)"
        }

        /// Must not inherit the layer-local FBO footprint: the final mesh vertex emits scene NDC, so the half-resolution target is scene-based (1920×1080 for a 4K frame).
        public static func makeDeferredSource(objectID: String, index: Int) -> String {
            let base = "\(deferredPrefix)\(objectID)"
            return index == 0 ? base : "\(base)_s\(index)"
        }

        public static func isDeferredSource(_ name: String) -> Bool {
            name.hasPrefix(deferredPrefix)
        }

        /// Only a genuine `<base>_s<N>` derived name returns its base; the base name returns nil so callers keep `?? name`.
        public static func baseName(of name: String) -> String? {
            guard name.hasPrefix(prefix),
                  let suffixStart = name.range(of: "_s", options: .backwards)?.lowerBound else {
                return nil
            }
            let suffix = name[name.index(suffixStart, offsetBy: 2)...]
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
            let base = String(name[..<suffixStart])
            return base.count > prefix.count ? base : nil
        }
    }

    /// Bare `_rt_imageLayerComposite` (no suffix) is a scene alias, not this family; `layerID` requires `_a`/`_b` so the vocabularies stay disjoint.
    public enum ImageLayerComposite {
        private static let prefix = "_rt_imageLayerComposite_"

        public static func make(objectID: String) -> CompositePair {
            CompositePair(a: "\(prefix)\(objectID)_a", b: "\(prefix)\(objectID)_b")
        }

        public static func layerID(from name: String) -> String? {
            guard name.hasPrefix(prefix), name.hasSuffix("_a") || name.hasSuffix("_b") else {
                return nil
            }
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -2)
            guard start < end else { return nil }
            return String(name[start..<end])
        }
    }

    public enum LayerGroup {
        private static let prefix = "_rt_layerGroup_"
        public static func make(objectID: String) -> String { "\(prefix)\(objectID)" }
        public static func matches(_ name: String) -> Bool { name.hasPrefix(prefix) }
    }

    /// Deliberately no `layerID(from:)`: created layers never enter the static topological sort, so this vocabulary must stay disjoint from `ImageLayerComposite`.
    public enum CreatedLayerComposite {
        private static let prefix = "_rt_createdLayerComposite_"
        public static func make(key: String) -> CompositePair {
            CompositePair(a: "\(prefix)\(key)_a", b: "\(prefix)\(key)_b")
        }
    }
}
