import simd

/// Setting `general.shadows` → render context +0x1ac (14010efb0.c:120-153); absent reads as "medium"
/// (140046f20.c:179-187).
public enum WPEParityShadowQuality {
    public static func level(_ setting: String?) -> Int32 {
        switch setting ?? "medium" {
        case "disabled": 0
        case "low": 1
        case "high": 3
        case "ultra": 4
        default: 2
        }
    }

    /// Shadow map edge in texels (14025d3e0.c:8-17).
    static func mapSize(_ quality: Int32) -> Int {
        switch quality {
        case 3: 512
        case 4: 1024
        default: 256
        }
    }
}

/// One frame's shadow atlas: light order, slots and quotas from 140190c80.c:536-1343, packing and viewport
/// passes from 140190c80.c:1385-2231. Spot cookies are not modelled.
public struct WPEParityShadowLayout: Sendable, Equatable {
    public struct Viewport: Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
    }

    /// A viewport and its g_ViewportViewProjectionMatrices slot, depth bias already applied.
    public struct Draw: Sendable, Equatable {
        public var viewport: Viewport
        public var viewProjection: simd_float4x4
    }

    public struct Entry: Sendable, Equatable {
        public var lightID: String
        public var isPoint: Bool
        /// Index into g_LFeature_ShadowPointProjection when `isPoint`, else into g_LFeature_ShadowProjection.
        public var slot: Int
        public var size: Int
        /// Top-left texel in the atlas.
        public var origin: SIMD2<Int>
        public var projection: simd_float4x4
        /// P · V; for a point light this is P alone (the face views live in `draws`).
        public var viewProjection: simd_float4x4
        /// (x / W, y / H, s / W, s / H) of the atlas size.
        public var rect: SIMD4<Float>
        public var draws: [Draw]
    }

    /// `_rt_shadowAtlas` size; .zero before any entry was ever placed.
    public var atlasSize: SIMD2<Int>
    public var entries: [Entry] = []
    /// Viewport passes of at most six draws, in submission order.
    public var batches: [[Draw]] = []
    public var projections: [simd_float4x4] = []
    public var projectionTransforms: [SIMD4<Float>] = []
    public var pointProjections: [SIMD4<Float>] = []
    public var pointProjectionTransforms: [SIMD4<Float>] = []

    /// `forward` is render context +0x160 and `eye` +0x68; `previousAtlasSize` is last frame's `atlasSize`, since
    /// the atlas only grows (140190c80.c:1533-1549).
    public init(document: WPESceneDocument, transforms: WPEParityLayerTransformSet, state: WPEParitySceneState?,
                quality: Int32, eye: SIMD3<Float>, forward: SIMD3<Float>, orthographic: Bool,
                previousAtlasSize: SIMD2<Int>? = nil) {
        atlasSize = previousAtlasSize ?? .zero
        guard quality != 0 else { return }
        let config = WPEParityLightConfig(general: document.resolvedGeneralJSON, shadowQuality: quality)
        let size = WPEParityShadowQuality.mapSize(quality)
        let radiansPerDegree: Float = 0.017453292
        var left = (point: config.point, spot: config.spot, directional: config.directional)
        var pointShadowsLeft = config.pointShadow
        // Spot shadows and directional lights draw from one quota of projection slots, one per light.
        var projectionsLeft = config.spotShadowCookie + config.spotCookie + config.spotShadow
            + 3 * config.directionalShadow
        let projectionCapacity = Int(projectionsLeft)
        var spotSlot = Int(config.spotShadowCookie + config.spotCookie)
        var cascadeSlot = spotSlot + Int(config.spotShadow)
        var pointSlot = 0
        for light in document.lightObjects where state?.isVisible(light.id) ?? light.visible {
            func scalar(_ name: String, _ fallback: Double) -> Float {
                if case let .vector(value)? = state?.scriptField(name, of: light.id) {
                    return value.x
                }
                return Float(fallback)
            }
            let world = transforms.world(light.id)
            let radius = scalar("radius", light.radius)
            func entry(_ slot: Int, _ projection: simd_float4x4, _ view: simd_float4x4) -> Entry {
                Entry(lightID: light.id, isPoint: false, slot: slot, size: size, origin: .zero,
                      projection: projection, viewProjection: projection * view, rect: .zero, draws: [])
            }
            switch light.type {
            case .point where left.point > 0:
                left.point -= 1
                guard light.castShadow, pointShadowsLeft > 0 else { continue }
                pointShadowsLeft -= 1
                // 14025d420.c:35-62.
                let fov: Float = quality <= 2 ? 94 : quality == 3 ? 92 : 91.2
                let near = orthographic ? 1 : max(0.05, Float(light.lightSourceSize))
                let projection = WPEParityCamera.perspective(fovY: fov * radiansPerDegree, aspect: 1, near: near,
                                                             far: max(radius, near + 0.01))
                pointProjections.setSlot(pointSlot, SIMD4(projection.columns.2.z, projection.columns.3.z,
                                                          projection.columns.2.w, projection.columns.3.w),
                                         capacity: Int(config.pointShadow), zero: .zero)
                entries.append(Entry(lightID: light.id, isPoint: true, slot: pointSlot, size: size, origin: .zero,
                                     projection: projection, viewProjection: projection, rect: .zero,
                                     draws: Self.pointFaces(projection, origin: Self.xyz(world.columns.3))))
                pointSlot += 1
            case .spot where left.spot > 0:
                left.spot -= 1
                guard light.castShadow, projectionsLeft > 0 else { continue }
                projectionsLeft -= 1
                // 14025d420.c:64-210: a view down the light's x axis, fov twice the outer cone.
                let unit = { (v: SIMD3<Float>) in
                    v * WPEParityUniformMatrices.fastInverseSquareRoot(simd_length_squared(v))
                }
                let view = Self.view(right: unit(Self.xyz(world.columns.2)), up: unit(Self.xyz(world.columns.1)),
                                     back: unit(-Self.xyz(world.columns.0)), origin: Self.xyz(world.columns.3))
                let near: Float = orthographic ? 1 : 0.05
                let outer = scalar("outercone", light.outerConeDegrees)
                let projection = WPEParityCamera.perspective(fovY: (outer + outer) * radiansPerDegree, aspect: 1,
                                                             near: near, far: max(radius, near + 0.01))
                let spot = entry(spotSlot, projection, view)
                projections.setSlot(spotSlot, spot.viewProjection, capacity: projectionCapacity, zero: simd_float4x4())
                entries.append(spot)
                spotSlot += 1
            case .directional where left.directional > 0:
                left.directional -= 1
                guard light.castShadow, projectionsLeft > 0 else { continue }
                projectionsLeft -= 1
                let axis = Self.xyz(world.columns.0), up = Self.xyz(world.columns.1)
                let side = Self.xyz(world.columns.2)
                let distances = SIMD3<Float>(light.cascadeDistances)
                // 14025d370.c:9-19: (radius × 2, depth) per cascade.
                let cascades: [(Float, Float)] = [
                    (distances.x, distances.y * 4), (distances.y, distances.y * 4),
                    (distances.z, max(distances.z * 1.5, distances.y * 4)),
                ]
                let unitAxis = simd_normalize(axis)
                for (extent, depth) in cascades {
                    let half = extent * 0.5
                    // 140190c80.c:938-967: the camera forward with half its light-axis component removed.
                    let bent = forward - unitAxis * (simd_dot(forward, unitAxis) * 0.5)
                    var centre = SIMD3(eye.x + bent.x * half, eye.y + bent.y * half,
                                       orthographic ? 0 : eye.z + bent.z * half)
                    // 140190c80.c:983-992 with elided arguments; assumed snapping to one shadow texel.
                    let texel = 2 * half / Float(size)
                    let alongUp = simd_dot(up, centre), alongSide = simd_dot(side, centre)
                    centre -= up * alongUp.truncatingRemainder(dividingBy: texel)
                    centre -= side * alongSide.truncatingRemainder(dividingBy: texel)
                    let view = Self.view(right: simd_normalize(side), up: simd_normalize(up), back: -unitAxis,
                                         origin: centre)
                    let projection = WPEParityCamera.ortho(left: -half, right: half, bottom: -half, top: half,
                                                           near: -depth / 2, far: depth / 2)
                    let cascade = entry(cascadeSlot, projection, view)
                    projections.setSlot(cascadeSlot, cascade.viewProjection, capacity: projectionCapacity,
                                        zero: simd_float4x4())
                    entries.append(cascade)
                    cascadeSlot += 1
                }
            default:
                break
            }
        }
        guard !entries.isEmpty else { return }
        let needed = Self.pack(&entries)
        if let previousAtlasSize, previousAtlasSize.x >= needed.x, previousAtlasSize.y >= needed.y {
            atlasSize = previousAtlasSize
        } else {
            atlasSize = needed
        }
        var staged: [Draw] = []
        for index in entries.indices {
            let entry = entries[index]
            let rect = SIMD4(Float(entry.origin.x) / Float(atlasSize.x), Float(entry.origin.y) / Float(atlasSize.y),
                             Float(entry.size) / Float(atlasSize.x), Float(entry.size) / Float(atlasSize.y))
            entries[index].rect = rect
            if entry.isPoint {
                pointProjectionTransforms.setSlot(entry.slot, rect, capacity: Int(config.pointShadow), zero: .zero)
                let half = entry.size / 2, third = entry.size / 3
                for face in entries[index].draws.indices {
                    entries[index].draws[face].viewport = Viewport(x: entry.origin.x + face % 2 * half,
                                                                   y: entry.origin.y + face / 2 * third,
                                                                   width: half, height: third)
                }
                batches.append(entries[index].draws)
                // The six faces overwrite the staging slots without flushing what was staged (140190c80.c:2183-2225).
                staged = Array(entries[index].draws.prefix(staged.count))
            } else {
                projectionTransforms.setSlot(entry.slot, rect, capacity: projectionCapacity, zero: .zero)
                var biased = entry.viewProjection
                biased.columns.3.z -= 0.0005
                let draw = Draw(viewport: Viewport(x: entry.origin.x, y: entry.origin.y, width: entry.size,
                                                   height: entry.size), viewProjection: biased)
                entries[index].draws = [draw]
                if staged.count == 6 {
                    batches.append(staged)
                    staged = []
                }
                staged.append(draw)
            }
        }
        if !staged.isEmpty {
            batches.append(staged)
        }
    }

    private static func xyz(_ column: SIMD4<Float>) -> SIMD3<Float> {
        SIMD3(column.x, column.y, column.z)
    }

    private static func view(right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>, origin: SIMD3<Float>)
        -> simd_float4x4 {
        simd_float4x4(rows: [
            SIMD4(right, -simd_dot(right, origin)), SIMD4(up, -simd_dot(up, origin)),
            SIMD4(back, -simd_dot(back, origin)), SIMD4(0, 0, 0, 1),
        ])
    }

    /// Face views are the transposed `viewMatrix` literals of CalculateProjectedCoordsPoint (common_pbr_2.h:167-235),
    /// in its viewport-offset order; P's m[3][2] is biased by 0.00333 (140190c80.c:1663).
    private static func pointFaces(_ projection: simd_float4x4, origin o: SIMD3<Float>) -> [Draw] {
        let faces: [[SIMD4<Float>]] = [
            [SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(-o.z, -o.y, o.x, 1)],
            [SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(o.z, -o.y, -o.x, 1)],
            [SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(-o.x, -o.z, o.y, 1)],
            [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(-o.x, o.z, -o.y, 1)],
            [SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(o.x, -o.y, o.z, 1)],
            [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-o.x, -o.y, -o.z, 1)],
        ]
        var biased = projection
        biased.columns.3.z -= 0.00333
        return faces.map {
            Draw(viewport: Viewport(x: 0, y: 0, width: 0, height: 0),
                 viewProjection: biased * simd_float4x4(columns: ($0[0], $0[1], $0[2], $0[3])))
        }
    }

    /// 140190c80.c:1417-1532: shelf nodes (x0, x1, y, top) from one 0x2000-wide node, entries in order. A node too
    /// narrow appends a full-width node at its raised top. Returns (max(2, max x + s), max(2, max y + s)).
    private static func pack(_ entries: inout [Entry]) -> SIMD2<Int> {
        var nodes: [(x0: Int, x1: Int, y: Int, top: Int)] = [(0, 0x2000, 0, 0)]
        var extent = SIMD2(2, 2)
        for index in entries.indices {
            let size = entries[index].size
            var node = 0
            while node < nodes.count {
                let top = max(nodes[node].y + size, nodes[node].top)
                nodes[node].top = top
                let (x0, y) = (nodes[node].x0, nodes[node].y)
                if size <= nodes[node].x1 - x0 {
                    entries[index].origin = SIMD2(x0, y)
                    extent = simd_max(extent, SIMD2(x0 + size, y + size))
                    nodes[node].x0 = x0 + size
                    nodes.append((x0, x0 + size, y + size, top))
                    break
                }
                nodes.append((0, 0x2000, top, top))
                node += 1
            }
        }
        return extent
    }
}

extension Array {
    /// A write into a fixed native slot: gaps read as `zero`, slots at or past `capacity` are dropped.
    mutating func setSlot(_ index: Int, _ value: Element, capacity: Int, zero: Element) {
        guard index < capacity else { return }
        if count <= index {
            append(contentsOf: repeatElement(zero, count: index + 1 - count))
        }
        self[index] = value
    }
}
