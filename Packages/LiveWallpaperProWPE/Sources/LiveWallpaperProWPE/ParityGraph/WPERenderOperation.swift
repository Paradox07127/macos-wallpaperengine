// Metal-free description of the D3D11 operation stream WPE issues in one frame.

public struct WPEResourceID: Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum WPEResourceLifetime: Hashable, Sendable {
    /// Contents before the first write of a frame are irrelevant and nothing is carried to the next frame.
    case frameTransient
    /// Caller-supplied; contents survive into the next frame and may be read outside the graph.
    case persistent
    /// A named RT in WPE's pool: contents survive between frames of this graph, but nothing outside reads them.
    /// The compiler treats it as `.frameTransient` when no access in the frame observes its entry contents.
    case pooled
    /// Owned outside the graph (images, video frames); never pooled or aliased.
    case imported
    /// Presented or handed out after the frame.
    case output
}

public struct WPELogicalResource: Hashable, Sendable {
    public let id: WPEResourceID
    public let width: Int
    public let height: Int
    /// Placeholder for the backend's pixel format; the compiler only compares it for equality.
    public let format: String
    public let mipCount: Int
    public let sampleCount: Int
    public let lifetime: WPEResourceLifetime

    public init(id: WPEResourceID, width: Int, height: Int, format: String = "rgba8unorm",
                mipCount: Int = 1, sampleCount: Int = 1, lifetime: WPEResourceLifetime) {
        self.id = id
        self.width = width
        self.height = height
        self.format = format
        self.mipCount = mipCount
        self.sampleCount = sampleCount
        self.lifetime = lifetime
    }
}

public struct WPETextureView: Hashable, Sendable {
    public let resource: WPEResourceID
    /// `nil` means every mip of the resource; normalization replaces it with the explicit range.
    public let mips: Range<Int>?

    public init(_ resource: WPEResourceID, mips: Range<Int>? = nil) {
        self.resource = resource
        self.mips = mips
    }
}

public struct WPEPassIdentity: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

/// Opaque key for the draw's complete fixed-function and shader state.
public struct WPEDrawStateKey: Hashable, Sendable {
    public let value: any Hashable & Sendable

    public init(_ value: some Hashable & Sendable) {
        self.value = value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        AnyHashable(lhs.value) == AnyHashable(rhs.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(AnyHashable(value))
    }
}

public struct WPEDrawOperation: Hashable, Sendable {
    public let reads: [WPETextureView]
    /// Blending (or any fixed-function path) reads the color attachments' existing contents.
    public let readsDestination: Bool
    /// Every pixel and channel of every bound color attachment is written without reading it.
    public let overwritesTargets: Bool
    public let depthTest: Bool
    public let depthWrite: Bool
    public let state: WPEDrawStateKey

    public init(reads: [WPETextureView] = [], readsDestination: Bool = false, overwritesTargets: Bool = false,
                depthTest: Bool = false, depthWrite: Bool = false, state: WPEDrawStateKey = WPEDrawStateKey(0)) {
        self.reads = reads
        self.readsDestination = readsDestination
        self.overwritesTargets = overwritesTargets
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.state = state
    }
}

public struct WPEClearColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct WPERenderOperation: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// OMSetRenderTargets: state only; it never opens an encoder by itself.
        case setTargets(color: [WPETextureView], depth: WPETextureView?)
        /// Clears the whole view regardless of the bound viewport.
        case clearColor(WPETextureView, WPEClearColor)
        case clearDepth(WPETextureView, depth: Double)
        case draw(WPEDrawOperation)
        /// CopyResource: identical extent, format, mips and samples.
        case copy(source: WPEResourceID, destination: WPEResourceID)
        case generateMips(WPEResourceID)
        /// ResolveSubresource of mip 0 from a multisampled resource.
        case resolve(source: WPEResourceID, destination: WPEResourceID)
    }

    public let pass: WPEPassIdentity
    public let kind: Kind

    public init(pass: WPEPassIdentity, _ kind: Kind) {
        self.pass = pass
        self.kind = kind
    }
}
