#include <metal_stdlib>

using namespace metal;

// Fragments return one opaque frame: progress 0 must equal `from` and progress 1 must equal `to`.
// uv follows the prototype ((0,0) bottom-left) while the input textures are top-left origin,
// so every texture lookup flips y; q is uv with x scaled by the aspect ratio.

struct WallpaperDistortionUniforms {
    float progress;
    float time;
    float aspect;
    float seed;
    float2 origin;
};

struct WallpaperDistortionVertexOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler distortionSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// Voronoi lattice density: cells per unit of screen height.
constant float distortionCrystalScale = 9.0f;

[[vertex]] WallpaperDistortionVertexOut wallpaperDistortionVertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2(float((vertexID << 1) & 2u), float(vertexID & 2u));
    WallpaperDistortionVertexOut out;
    out.position = float4(corner * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = corner;
    return out;
}

static inline float3 distortionSample(texture2d<float> texture, float2 uv) {
    return texture.sample(distortionSampler, float2(uv.x, 1.0f - uv.y)).rgb;
}

// Must stay custom: callers pass edge0 > edge1, which metal::smoothstep leaves undefined.
static inline float distortionSmooth(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

static inline float distortionEaseInOut(float x) {
    float t = clamp(x, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

static inline float distortionHash(float2 p) {
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
}

static inline float2 distortionHash2(float2 p) {
    float n = distortionHash(p);
    return float2(n, distortionHash(p + n));
}

static inline float3 distortionScreen(float3 base, float3 light) {
    return 1.0f - (1.0f - base) * (1.0f - clamp(light, 0.0f, 1.0f));
}

static inline float2 distortionAspect(float2 uv, constant WallpaperDistortionUniforms &u) {
    return float2(uv.x * u.aspect, uv.y);
}

// MARK: - Ripple

[[fragment]] float4 wallpaperDistortionRipple(
    WallpaperDistortionVertexOut in [[stage_in]],
    constant WallpaperDistortionUniforms &u [[buffer(0)]],
    texture2d<float> from [[texture(0)]],
    texture2d<float> to [[texture(1)]]
) {
    float p = u.progress;
    float2 q = distortionAspect(in.uv, u);
    float2 o = distortionAspect(u.origin, u);
    float2 dv = q - o;
    float r = length(dv);
    float2 dir = r > 0.0001f ? dv / r : float2(0.0f);
    float maxRadius = length(float2(max(o.x, u.aspect - o.x), max(o.y, 1.0f - o.y))) + 0.2f;
    float radius = (0.6f * distortionEaseInOut(p) + 0.4f * p) * maxRadius;
    float x = (r - radius) / 0.09f;
    float band = exp(-x * x * 1.5f);
    // The front starts at the origin at full amplitude; fading it in keeps progress 0 exactly `from`.
    float start = distortionSmooth(0.0f, 0.04f, p);
    float disp = -sin(x * 2.2f) * band * 0.035f * (1.0f - p * 0.7f);
    disp += sin((radius - r) * 45.0f) * exp(-(radius - r) * 7.0f) * 0.006f * step(r, radius) * (1.0f - p);
    disp *= start;
    float2 shifted = in.uv + float2(dir.x / u.aspect, dir.y) * disp;
    float m = max(distortionSmooth(radius + 0.01f, radius - 0.01f, r) * start, distortionSmooth(0.92f, 1.0f, p));
    float3 color = mix(distortionSample(from, shifted), distortionSample(to, shifted), m);
    float glint = band * (0.5f + 0.5f * cos(x * 2.2f)) * 0.22f * (1.0f - p) * start;
    return float4(distortionScreen(color, float3(0.85f, 0.95f, 1.0f) * glint), 1.0f);
}

// MARK: - Blinds

[[fragment]] float4 wallpaperDistortionBlinds(
    WallpaperDistortionVertexOut in [[stage_in]],
    constant WallpaperDistortionUniforms &u [[buffer(0)]],
    texture2d<float> from [[texture(0)]],
    texture2d<float> to [[texture(1)]]
) {
    const float slats = 14.0f;
    float2 uv = in.uv;
    float x = uv.x * slats;
    float slat = floor(x);
    float local = fract(x) - 0.5f;
    float f = clamp((u.progress - slat / slats * 0.55f) / 0.38f, 0.0f, 1.0f);
    if (f <= 0.0f) {
        return float4(distortionSample(from, uv), 1.0f);
    }
    if (f >= 1.0f) {
        return float4(distortionSample(to, uv), 1.0f);
    }
    float angle = distortionEaseInOut(f) * M_PI_F;
    float c = cos(angle);
    float width = abs(c);
    float sx = local / max(width, 0.02f);
    float perspective = 1.0f + sx * sin(angle) * 0.6f;
    float sy = (uv.y - 0.5f) / perspective + 0.5f;
    float inside = step(abs(sx), 0.5f) * step(0.0f, sy) * step(sy, 1.0f);
    float2 source = float2((slat + 0.5f + sx) / slats, sy);
    float3 face = c > 0.0f ? distortionSample(from, source) : distortionSample(to, source);
    float3 color = face * (0.45f + 0.55f * width) + pow(1.0f - width, 8.0f) * 0.45f;
    color = mix(float3(0.05f, 0.05f, 0.07f) + distortionSample(from, uv) * 0.14f, color, inside);
    return float4(color, 1.0f);
}

// MARK: - Crystal

// Once per transition: rg = Voronoi cell id + 1, b = edge shading 0...255 (0 on a cell border).
[[fragment]] uint4 wallpaperDistortionCrystalCells(
    WallpaperDistortionVertexOut in [[stage_in]],
    constant WallpaperDistortionUniforms &u [[buffer(0)]]
) {
    float2 x = distortionAspect(in.uv, u) * distortionCrystalScale;
    float2 n = floor(x);
    float2 f = fract(x);
    float2 nearestCell = float2(0.0f);
    float2 nearestOffset = float2(0.0f);
    float nearest = 8.0f;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(float(i), float(j));
            float2 r = g + distortionHash2(n + g) - f;
            float d = dot(r, r);
            if (d < nearest) {
                nearest = d;
                nearestOffset = r;
                nearestCell = g;
            }
        }
    }
    float border = 8.0f;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 g = nearestCell + float2(float(i), float(j));
            float2 r = g + distortionHash2(n + g) - f;
            float2 delta = r - nearestOffset;
            if (dot(delta, delta) > 0.00001f) {
                border = min(border, dot(0.5f * (nearestOffset + r), normalize(delta)));
            }
        }
    }
    float2 id = n + nearestCell;
    float shade = distortionSmooth(0.0f, 0.008f, border / distortionCrystalScale);
    return uint4(uint(id.x + 1.0f), uint(id.y + 1.0f), uint(rint(shade * 255.0f)), 0u);
}

[[fragment]] float4 wallpaperDistortionCrystal(
    WallpaperDistortionVertexOut in [[stage_in]],
    constant WallpaperDistortionUniforms &u [[buffer(0)]],
    texture2d<float> from [[texture(0)]],
    texture2d<float> to [[texture(1)]],
    texture2d<uint> cells [[texture(2)]]
) {
    uint4 cell = cells.read(uint2(in.position.xy));
    float2 id = float2(cell.xy) - 1.0f;
    float2 center = (id + distortionHash2(id)) / distortionCrystalScale;
    float2 o = distortionAspect(u.origin, u);
    float maxDistance = length(float2(max(o.x, u.aspect - o.x), max(o.y, 1.0f - o.y)));
    float delay = length(center - o) / maxDistance * 0.66f + distortionHash(id) * 0.12f;
    float f = clamp((u.progress - delay) / 0.2f, 0.0f, 1.0f);
    if (f <= 0.0f) {
        return float4(distortionSample(from, in.uv), 1.0f);
    }
    if (f >= 1.0f) {
        return float4(distortionSample(to, in.uv), 1.0f);
    }
    float angle = distortionEaseInOut(f) * M_PI_F;
    float squash = abs(cos(angle));
    float tilt = distortionHash(id + 3.1f) * M_PI_F;
    float2 axis = float2(cos(tilt), sin(tilt));
    float2 across = float2(-axis.y, axis.x);
    float2 local = distortionAspect(in.uv, u) - center;
    float2 source = center + axis * dot(local, axis) + across * (dot(local, across) / max(squash, 0.02f));
    float2 sourceUV = float2(source.x / u.aspect, source.y);
    // The cell map only covers the screen: off-screen sources take the nearest edge texel's cell.
    float2 size = float2(float(cells.get_width()), float(cells.get_height()));
    uint2 sourceTexel = uint2(clamp(float2(sourceUV.x, 1.0f - sourceUV.y) * size, float2(0.0f), size - 1.0f));
    float inside = all(cells.read(sourceTexel).xy == cell.xy) ? 1.0f : 0.0f;
    float3 face = angle < M_PI_2_F ? distortionSample(from, sourceUV) : distortionSample(to, sourceUV);
    float3 color = face * (0.5f + 0.5f * squash) + pow(1.0f - squash, 6.0f) * 0.5f;
    color = mix(float3(0.05f, 0.05f, 0.07f) + distortionSample(from, in.uv) * 0.14f, color, inside);
    color *= 0.75f + 0.25f * float(cell.z) / 255.0f;
    return float4(color, 1.0f);
}
