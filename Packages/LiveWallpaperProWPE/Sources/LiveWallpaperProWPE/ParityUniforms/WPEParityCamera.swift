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

/// General `fov` (degrees), `nearz` and `farz` of a scene whose `orthogonalprojection` is null (Main+0x140/0x14c/0x150,
/// defaults from 140186c90.c:137-141).
public struct WPEParityScenePerspective: Sendable, Equatable {
    public var fov: Float
    public var near: Float
    public var far: Float

    public init(fov: Float = 50, near: Float = 0.1, far: Float = 10000) {
        self.fov = fov
        self.near = near
        self.far = far
    }
}

/// WPE's scene camera: lookAtRH view and the ortho canvas projection (1401891a0.c, 0x140183e95), or the perspective
/// one when `scenePerspective` is set (140183a70.c:36-68).
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
    /// Nil for an orthographic scene.
    public var scenePerspective: WPEParityScenePerspective?

    public init(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>, size: SIMD2<Float>,
                renderTargetSize: SIMD2<Float>, zoom: Float = 1, alignment: WPEParityCameraAlignment = .noCrop,
                parallaxAmount: Float? = nil, perspectiveFOV: Float = 50, shake: WPEParityCameraShake? = nil,
                scenePerspective: WPEParityScenePerspective? = nil) {
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
        self.scenePerspective = scenePerspective
    }

    /// `cameraZoom` is the camera path or camera object zoom for the frame.
    public init(document: WPESceneDocument, renderTargetSize: SIMD2<Float>,
                alignment: WPEParityCameraAlignment = .noCrop, cameraZoom: Float = 1) {
        let general = document.general
        let ortho = general.orthogonalProjection
        let size = Self.autoLayer(document)?.size.map { SIMD2(Float($0.width), Float($0.height)) }
            ?? SIMD2(Float(ortho.width), Float(ortho.height))
        let parallax = Self.parallaxSettings(general: document.resolvedGeneralJSON)
        let resolved = document.resolvedGeneralJSON
        func value(_ key: String, _ fallback: Float) -> Float {
            let raw = resolved[key]
            return WPEParityProgramScene.number(raw?["value"] ?? raw).map(Float.init) ?? fallback
        }
        let defaults = WPEParityScenePerspective()
        let perspective = general.usesPerspectiveProjection
            ? WPEParityScenePerspective(fov: document.cameraMotion == nil ? value("fov", defaults.fov) : Float(document.camera.fov),
                                        near: value("nearz", defaults.near),
                                        far: value("farz", defaults.far))
            : nil
        // The V parallax push needs an orthographic scene (14018aac0.c:87).
        self.init(eye: SIMD3(document.camera.eye), center: SIMD3(document.camera.center),
                  up: SIMD3(document.camera.up), size: size, renderTargetSize: renderTargetSize,
                  zoom: Float(general.zoom) * cameraZoom, alignment: alignment,
                  parallaxAmount: parallax.enabled && perspective == nil ? Float(parallax.amount) : nil,
                  perspectiveFOV: Float(general.perspectiveOverrideFOV.resolvedValue),
                  shake: WPEParityScriptProperty.sceneBoolValue(fromJSON: resolved["camerashake"]) == true
                      ? WPEParityCameraShake(general: resolved, orthographic: perspective == nil) : nil,
                  scenePerspective: perspective)
    }

    /// Native constructor values and strict typed fromJSON seeds, before any SceneScript writes.
    public static func parallaxSettings(general: WPESceneJSONValue) -> WPESceneCameraParallaxSettings {
        let defaults = WPESceneCameraParallaxSettings.disabled
        return WPESceneCameraParallaxSettings(
            enabled: WPEParityScriptProperty.sceneBoolValue(fromJSON: general["cameraparallax"]) ?? defaults.enabled,
            amount: Double(WPEParityScriptProperty.sceneFloatValue(fromJSON: general["cameraparallaxamount"]) ?? Float(defaults.amount)),
            delay: Double(WPEParityScriptProperty.sceneFloatValue(fromJSON: general["cameraparallaxdelay"]) ?? Float(defaults.delay)),
            mouseInfluence: Double(WPEParityScriptProperty.sceneFloatValue(fromJSON: general["cameraparallaxmouseinfluence"]) ?? Float(defaults.mouseInfluence))
        )
    }

    /// The authored root camera, before any camera object takes control. A hidden camera object must not leave
    /// its parse-time pose behind when playback falls back to the root camera or its paths.
    public static func root(document: WPESceneDocument, renderTargetSize: SIMD2<Float>,
                            alignment: WPEParityCameraAlignment = .noCrop) -> Self {
        var camera = Self(document: document, renderTargetSize: renderTargetSize, alignment: alignment)
        camera.eye = SIMD3(document.staticCamera.eye)
        camera.center = SIMD3(document.staticCamera.center)
        camera.up = SIMD3(document.staticCamera.up)
        if camera.scenePerspective != nil {
            let raw = document.resolvedGeneralJSON["fov"]
            camera.scenePerspective?.fov = WPEParityProgramScene.number(raw?["value"] ?? raw).map(Float.init) ?? 50
        }
        return camera
    }

    /// 1401891a0.c:57-67: the last camera whose own bit and all ancestors are visible wins. Selection uses the
    /// resolved authored order, independently of whether the object has a script binding.
    public static func activeObjectID(document: WPESceneDocument, state: WPEParitySceneState) -> String? {
        for object in document.resolvedObjectsJSON.reversed() {
            guard case .string? = object["camera"], let id = WPEParitySceneAnimations.id(object),
                  state.isVisible(id) else { continue }
            return id
        }
        return nil
    }

    /// 1401891a0.c:85-132: use W (without layer alignment), not the object's local origin/angles. Camera FOV
    /// controls a genuinely perspective scene; the layer's perspectiveoverridefov remains a separate setting.
    /// The caller advances root paths only when no object is active, then applies shake to the selected pose.
    public func applyingObject(world: simd_float4x4, fov: Float?, zoom: Float, generalZoom: Float) -> Self {
        var camera = self
        let eye = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        camera.eye = eye
        camera.center = eye - SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)
        camera.up = SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z)
        camera.zoom = generalZoom * zoom
        if let fov, camera.scenePerspective != nil {
            camera.scenePerspective?.fov = fov
        }
        return camera
    }

    /// Resolves the selected object's typed script fields over its authored seeds, then native constructor
    /// defaults (H08: fov 50 / zoom 1). Keeps internal JSON identity/scalar helpers inside the package.
    public func applyingObject(world: simd_float4x4, objectID: String, document: WPESceneDocument,
                               state: WPEParitySceneState, generalZoom: Float) -> Self {
        let object = document.resolvedObjectsJSON.first { WPEParitySceneAnimations.id($0) == objectID }
        func scalar(_ name: String, fallback: Float) -> Float {
            if case let .vector(value)? = state.scriptField(name, of: objectID) {
                return value.x
            }
            let raw = object?[name]
            return WPEParityProgramScene.number(raw?["value"] ?? raw).map(Float.init) ?? fallback
        }
        return applyingObject(world: world, fov: scalar("fov", fallback: 50),
                              zoom: scalar("zoom", fallback: 1), generalZoom: generalZoom)
    }

    /// SceneScript cursorWorldPosition (14018e070 mode 0 / 14019df90): viewport depth .5 becomes clip depth 0.
    /// The native caller drops Z only in an orthographic scene; a perspective scene keeps the unprojected Z.
    /// `normalizedPointer` uses the client convention, y down.
    public func cursorWorld(normalizedPointer: SIMD2<Float>) -> SIMD3<Float> {
        let clip = SIMD4<Float>(normalizedPointer.x * 2 - 1, 1 - normalizedPointer.y * 2, 0, 1)
        let homogeneous = (projection * view).inverse * clip
        var world = SIMD3(homogeneous.x, homogeneous.y, homogeneous.z) / homogeneous.w
        if scenePerspective == nil {
            world.z = 0
        }
        return world
    }

    /// The camera on a path pose, which comes before the shake (1401891a0.c:253-255); the projection zooms by
    /// general zoom × pose zoom (14017fa70.c:229).
    public func posed(_ pose: WPEParityCameraPose, generalZoom: Float) -> WPEParityCamera {
        var camera = self
        (camera.eye, camera.center, camera.up) = (pose.eye, pose.center, pose.up)
        camera.zoom = generalZoom * pose.zoom
        return camera
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
        let crop = alignmentCrop
        let left = alignment.flipHorizontal ? size.x - crop.x : crop.x
        let right = alignment.flipHorizontal ? crop.y : size.x - crop.y
        return SIMD4(left, right, crop.z, size.y - crop.w)
    }

    /// Canvas pixels cropped off the left, right, bottom and top.
    var alignmentCrop: SIMD4<Float> {
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
        return crop
    }

    /// Ortho over `bounds` with depth ±2000, zoomed about the canvas centre (14017fa70.c:227-346). A perspective
    /// scene takes the render-target aspect, no crop and no zoom, its first column negated under fliph
    /// (140183a70.c:36-68); the fov clamp is 1401891a0.c:279-287.
    public var projection: simd_float4x4 {
        if let scenePerspective {
            let fov = min(max(scenePerspective.fov, 0.1), 179.9) * (Float.pi / 180)
            var perspective = Self.perspective(fovY: fov, aspect: renderTargetSize.x / renderTargetSize.y,
                                               near: scenePerspective.near, far: scenePerspective.far)
            if alignment.flipHorizontal {
                perspective.columns.0 = -perspective.columns.0
            }
            return perspective
        }
        let b = bounds
        let ortho = Self.ortho(left: b.x, right: b.y, bottom: b.z, top: b.w, near: -2000, far: 2000)
        return ortho * Self.translation(SIMD3(size / 2, 0)) * simd_float4x4(diagonal: SIMD4(zoom, zoom, 1, 1))
            * Self.translation(SIMD3(-size / 2, 0))
    }

    /// The eye itself in a perspective scene (1401891a0.c:391-397).
    public var eyePosition: SIMD3<Float> {
        scenePerspective == nil ? WPEParityUniformParallax.eyePosition2D(eye: SIMD2(eye.x, eye.y), ortho: size) : eye
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

    /// Replacement P for a top-level `perspective` object (obj+0x120 bit 0x80).
    public var perspectiveProjection: simd_float4x4 {
        pushPerspective(view: view, projection: projection).projection
    }

    /// Replacement V for a top-level `perspective` object.
    public var perspectiveView: simd_float4x4 {
        pushPerspective(view: view, projection: projection).view
    }

    /// FUN_1401e5b60 on the V and P in force, the scene's or a parent composite's: V moves by the unmirrored crop
    /// centre (W·cx, H·cy; 140183a70.c:136-138) and back by D = (1/P.m5)/tan(fov/2); P becomes the perspective,
    /// its first column negated under fliph (1401e5b60.c:28-43).
    public func pushPerspective(view: simd_float4x4, projection: simd_float4x4)
        -> (view: simd_float4x4, projection: simd_float4x4) {
        let crop = alignmentCrop
        // A perspective scene zeroes the crop centre (140183a70.c:37).
        let centre = scenePerspective != nil ? .zero
            : SIMD2((size.x * 0.5 - (crop.y - crop.x) * 0.5) / size.x,
                    (size.y * 0.5 - (crop.w - crop.z) * 0.5) / size.y)
        let distance = 1 / projection.columns.1.y / tan(perspectiveFOVRadians / 2)
        var pushed = view
        // W and H are the integer canvas size (ctx+0x84/0x88).
        pushed.columns.3.x -= size.x.rounded(.towardZero) * centre.x
        pushed.columns.3.y -= size.y.rounded(.towardZero) * centre.y
        pushed.columns.3.z = -distance
        var perspective = Self.perspective(fovY: perspectiveFOVRadians,
                                           aspect: renderTargetSize.x / renderTargetSize.y,
                                           near: 5, far: max(15000, distance + 1000))
        if alignment.flipHorizontal {
            perspective.columns.0 = -perspective.columns.0
        }
        return (pushed, perspective)
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

    /// FUN_14009a360, XMMatrixPerspectiveFovRH with near and far swapped: reversed depth, `near` maps to 1.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let focal = 1 / tan(fovY / 2)
        let range = near / (far - near)
        return simd_float4x4(rows: [
            SIMD4(focal / aspect, 0, 0, 0),
            SIMD4(0, focal, 0, 0),
            SIMD4(0, 0, range, range * far),
            SIMD4(0, 0, -1, 0),
        ])
    }

    static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset, 1)
        return matrix
    }
}
