import simd

/// User wallpaper alignment (Main+0x124, fliph Main+0x128 bit 0x800; 140181f30.c).
public struct WPEParityCameraAlignment: Sendable, Equatable {
    /// 2 never crops; every other mode crops the canvas to the render-target aspect.
    public var mode: Int
    /// `alignmentposition`, 0...100.
    public var position: Float
    public var flipHorizontal: Bool

    public init(mode: Int = 2, position: Float = 50, flipHorizontal: Bool = false) {
        self.mode = mode
        self.position = position
        self.flipHorizontal = flipHorizontal
    }

    public static let noCrop = Self()
}

/// WPE's 2D scene camera: lookAtRH view and the ortho canvas projection (1401891a0.c, 0x140183e95).
public struct WPEParityCamera: Sendable, Equatable {
    public var eye: SIMD3<Float>
    public var center: SIMD3<Float>
    public var up: SIMD3<Float>
    /// `orthogonalprojection` width and height.
    public var size: SIMD2<Float>
    public var renderTargetSize: SIMD2<Float>
    /// General zoom × camera zoom.
    public var zoom: Float
    public var alignment: WPEParityCameraAlignment
    /// `cameraparallaxamount` when camera parallax is on.
    public var parallaxAmount: Float?
    /// `perspectiveoverridefov` in degrees.
    public var perspectiveFOV: Float
    public var shake: WPEParityCameraShake?

    public init(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>, size: SIMD2<Float>,
                renderTargetSize: SIMD2<Float>, zoom: Float = 1, alignment: WPEParityCameraAlignment = .noCrop,
                parallaxAmount: Float? = nil, perspectiveFOV: Float = 50, shake: WPEParityCameraShake? = nil) {
        self.eye = eye
        self.center = center
        self.up = up
        self.size = size
        self.renderTargetSize = renderTargetSize
        self.zoom = zoom
        self.alignment = alignment
        self.parallaxAmount = parallaxAmount
        self.perspectiveFOV = perspectiveFOV
        self.shake = shake
    }

    /// `cameraZoom` is the camera path or camera object zoom for the frame.
    public init(document: WPESceneDocument, renderTargetSize: SIMD2<Float>,
                alignment: WPEParityCameraAlignment = .noCrop, cameraZoom: Float = 1) {
        let general = document.general
        let ortho = general.orthogonalProjection
        let size = Self.autoLayer(document)?.size.map { SIMD2(Float($0.width), Float($0.height)) }
            ?? SIMD2(Float(ortho.width), Float(ortho.height))
        let parallax = general.cameraParallax
        self.init(eye: SIMD3(document.camera.eye), center: SIMD3(document.camera.center),
                  up: SIMD3(document.camera.up), size: size, renderTargetSize: renderTargetSize,
                  zoom: Float(general.zoom) * cameraZoom, alignment: alignment,
                  parallaxAmount: parallax.enabled ? Float(parallax.amount) : nil,
                  perspectiveFOV: Float(general.perspectiveOverrideFOV.resolvedValue),
                  shake: WPEParityCameraShake(general: general))
    }

    /// The camera at g_Time `time`; the shake comes before parallax and lookAt (1401891a0.c:288-363).
    public func shaken(time: Float) -> WPEParityCamera {
        guard let shake else { return self }
        var camera = self
        (camera.eye, camera.center) = shake.shaken(eye: eye, center: center, time: time, orthoHeight: size.y)
        return camera
    }

    /// `"auto": true` sizes the canvas from the first image layer and centres that layer (14018b2c0.c:22-33).
    static func autoLayer(_ document: WPESceneDocument) -> WPESceneImageObject? {
        let auto = document.sourceJSON["general"]?["orthogonalprojection"]?["auto"]
        guard WPEParityProgramScene.flag(auto) else { return nil }
        return document.imageObjects.first { $0.size != nil }
    }

    public var view: simd_float4x4 {
        Self.lookAt(eye: eye, center: center, up: up)
    }

    /// Ortho (left, right, bottom, top) after the alignment crop and fliph mirror.
    public var bounds: SIMD4<Float> {
        var crop = SIMD4<Float>.zero
        if alignment.mode != 2 {
            let position = alignment.position * 0.01
            let horizontal = size.x - size.y * renderTargetSize.x / renderTargetSize.y
            let vertical = size.y - size.x * renderTargetSize.y / renderTargetSize.x
            if horizontal > 0 {
                crop.x = (1 - position) * horizontal
                crop.y = position * horizontal
            } else if vertical > 0 {
                crop.z = (1 - position) * vertical
                crop.w = position * vertical
            }
        }
        let left = alignment.flipHorizontal ? size.x - crop.x : crop.x
        let right = alignment.flipHorizontal ? crop.y : size.x - crop.y
        return SIMD4(left, right, crop.z, size.y - crop.w)
    }

    /// Ortho over `bounds` with depth ±2000, zoomed about the canvas centre (14017fa70.c:227-346).
    public var projection: simd_float4x4 {
        let b = bounds
        let ortho = Self.ortho(left: b.x, right: b.y, bottom: b.z, top: b.w, near: -2000, far: 2000)
        return ortho * Self.translation(SIMD3(size / 2, 0)) * simd_float4x4(diagonal: SIMD4(zoom, zoom, 1, 1))
            * Self.translation(SIMD3(-size / 2, 0))
    }

    public var eyePosition: SIMD3<Float> {
        WPEParityUniformParallax.eyePosition2D(eye: SIMD2(eye.x, eye.y), ortho: size)
    }

    /// V·T(p) with p = (root origin − m)·amount·root depth; `smoothed` is `WPEParityUniformParallax.smoothed`
    /// (14018aac0.c:87-165).
    public func view(parallaxRoot origin: SIMD2<Float>, depth: SIMD2<Float>, smoothed: SIMD2<Float>)
        -> simd_float4x4 {
        guard let parallaxAmount else { return view }
        let offset = (origin - smoothed) * parallaxAmount * depth
        return view * Self.translation(SIMD3(offset, 0))
    }

    private var perspectiveFOVRadians: Float {
        min(max(perspectiveFOV, 0.1), 179.9) * .pi / 180
    }

    /// Distance at which the perspective frustum spans the ortho canvas height (0x1401e5b6e-c47).
    public var perspectiveDistance: Float {
        1 / projection.columns.1.y / tan(perspectiveFOVRadians / 2)
    }

    /// Replacement P for `perspective` objects (obj+0x120 bit 0x80).
    public var perspectiveProjection: simd_float4x4 {
        let far = max(15000, perspectiveDistance + 1000)
        return Self.perspective(fovY: perspectiveFOVRadians, aspect: renderTargetSize.x / renderTargetSize.y,
                                near: 5, far: far)
    }

    /// Replacement V for `perspective` objects: the visible canvas centre moved to the axis, pushed back by D.
    public var perspectiveView: simd_float4x4 {
        let b = bounds
        var matrix = view
        matrix.columns.3.x -= (b.x + b.y) / 2
        matrix.columns.3.y -= (b.z + b.w) / 2
        matrix.columns.3.z = -perspectiveDistance
        return matrix
    }

    /// FUN_14009a630: z in [near, far] maps to [0, 1].
    public static func ortho(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float)
        -> simd_float4x4 {
        simd_float4x4(rows: [
            SIMD4(2 / (right - left), 0, 0, -(right + left) / (right - left)),
            SIMD4(0, 2 / (top - bottom), 0, -(top + bottom) / (top - bottom)),
            SIMD4(0, 0, 1 / (far - near), -near / (far - near)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// glm lookAtRH (FUN_14019d920).
    public static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(center - eye)
        let side = simd_normalize(simd_cross(forward, up))
        let upward = simd_cross(side, forward)
        return simd_float4x4(rows: [
            SIMD4(side, -simd_dot(side, eye)),
            SIMD4(upward, -simd_dot(upward, eye)),
            SIMD4(-forward, simd_dot(forward, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// Right-handed perspective with depth in [0, 1].
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let focal = 1 / tan(fovY / 2)
        return simd_float4x4(rows: [
            SIMD4(focal / aspect, 0, 0, 0),
            SIMD4(0, focal, 0, 0),
            SIMD4(0, 0, far / (near - far), -far * near / (far - near)),
            SIMD4(0, 0, -1, 0),
        ])
    }

    static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset, 1)
        return matrix
    }
}
