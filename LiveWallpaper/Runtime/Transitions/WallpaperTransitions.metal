#include <metal_stdlib>

using namespace metal;

// Mask fragments return how much of the outgoing wallpaper stays: alpha 1 keeps it, 0 cuts it away.
// Light fragments return premultiplied colour for a transparent overlay window.
// Coordinates follow the prototype: uv (0,0) is bottom-left, q is uv with x scaled by the aspect ratio.

struct WallpaperTransitionUniforms {
    float progress;
    float time;
    float aspect;
    float seed;
    float2 origin;
    float2 regionOrigin;
    float2 regionSize;
    float canvasAspect;
};

struct WallpaperTransitionVertexOut {
    float4 position [[position]];
    float2 uv;
};

[[vertex]] WallpaperTransitionVertexOut wallpaperTransitionVertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2(float((vertexID << 1) & 2u), float(vertexID & 2u));
    WallpaperTransitionVertexOut out;
    out.position = float4(corner * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = corner;
    return out;
}

static inline float transitionSmooth(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

static inline float transitionEaseInOut(float x) {
    float t = clamp(x, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

static inline float transitionEaseOut(float x) {
    float t = clamp(x, 0.0f, 1.0f);
    return 1.0f - (1.0f - t) * (1.0f - t);
}

static inline float transitionHash(float2 p) {
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
}

static inline float2 transitionHash2(float2 p) {
    float n = transitionHash(p);
    return float2(n, transitionHash(p + n));
}

static inline float transitionValueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    float a = transitionHash(i);
    float b = transitionHash(i + float2(1.0f, 0.0f));
    float c = transitionHash(i + float2(0.0f, 1.0f));
    float d = transitionHash(i + float2(1.0f, 1.0f));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static inline float transitionFBM(float2 p) {
    float value = 0.0f;
    float amplitude = 0.5f;
    for (int i = 0; i < 5; i++) {
        value += amplitude * transitionValueNoise(p);
        p = p * 2.02f + 17.0f;
        amplitude *= 0.5f;
    }
    return value;
}

static inline float transitionSegmentDistance(float2 p, float2 a, float2 b, thread float &h) {
    float2 pa = p - a;
    float2 ba = b - a;
    h = clamp(dot(pa, ba) / dot(ba, ba), 0.0f, 1.0f);
    return length(pa - ba * h);
}

static inline float2 transitionAspect(float2 uv, constant WallpaperTransitionUniforms &u) {
    return float2(uv.x * u.aspect, uv.y);
}

// Like transitionAspect, but on the canvas shared by every display, in canvas heights.
static inline float2 transitionCanvasPoint(float2 uv, constant WallpaperTransitionUniforms &u) {
    return u.regionOrigin + uv * u.regionSize;
}

// Screen-blends `light` over whatever is below, approximated with one alpha, then scaled by a
// start/end envelope so the overlay is fully transparent at progress 0 and 1.
static inline float4 transitionLight(float3 light, float darken, float progress) {
    float envelope = transitionSmooth(0.0f, 0.03f, progress) * (1.0f - transitionSmooth(0.97f, 1.0f, progress));
    float3 color = clamp(light, 0.0f, 1.0f) * envelope;
    float glow = max(color.r, max(color.g, color.b));
    float alpha = 1.0f - (1.0f - clamp(darken, 0.0f, 1.0f) * envelope) * (1.0f - glow);
    return float4(color, alpha);
}

// MARK: - Meteor

struct MeteorGeometry {
    float2 q;
    float2 start;
    float2 end;
    float distance;
    float along;
    float age;
    float growth;
    float radius;
};

constant float meteorHeadTime = 0.3f;

static inline MeteorGeometry meteorGeometry(float2 uv, constant WallpaperTransitionUniforms &u) {
    MeteorGeometry g;
    g.q = transitionCanvasPoint(uv, u);
    if (u.origin.x > 0.5f) {
        g.q.x = u.canvasAspect - g.q.x;
    }
    g.start = float2(-0.2f, 0.98f + (u.seed - 0.5f) * 0.16f);
    g.end = float2(u.canvasAspect + 0.2f, 0.18f - (u.seed - 0.5f) * 0.16f);
    g.distance = transitionSegmentDistance(g.q, g.start, g.end, g.along);
    float pass = meteorHeadTime * (1.0f - sqrt(max(1.0f - g.along, 0.0f)));
    g.age = u.progress - pass;
    g.growth = clamp((g.age - 0.04f) / 0.84f, 0.0f, 1.0f);
    float noise = transitionFBM(g.q * 3.2f + float2(u.seed * 10.0f, u.time * 0.15f));
    g.radius = powr(g.growth, 1.6f) * 1.1f * (0.8f + 0.45f * noise);
    return g;
}

[[fragment]] float4 wallpaperTransitionMeteorMask(WallpaperTransitionVertexOut in [[stage_in]],
                                                  constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    MeteorGeometry g = meteorGeometry(in.uv, u);
    float revealed = g.age > 0.04f ? transitionSmooth(g.radius + 0.012f, g.radius - 0.012f, g.distance) : 0.0f;
    revealed = max(revealed, transitionSmooth(0.9f, 1.0f, u.progress));
    return float4(1.0f - revealed);
}

[[fragment]] float4 wallpaperTransitionMeteorLight(WallpaperTransitionVertexOut in [[stage_in]],
                                                   constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    MeteorGeometry g = meteorGeometry(in.uv, u);
    float2 head = mix(g.start, g.end, transitionEaseOut(u.progress / meteorHeadTime));
    float edge = (g.age > 0.04f && g.growth > 0.0f)
        ? exp(-abs(g.distance - g.radius) * 45.0f) * (1.0f - g.growth) * 1.3f
        : 0.0f;
    float trailAlong;
    float trailDistance = transitionSegmentDistance(g.q, g.start, head, trailAlong);
    float behind = length(head - g.start) * (1.0f - trailAlong);
    float trail = exp(-trailDistance * 150.0f) * exp(-behind * 2.4f)
        * (1.0f - transitionSmooth(meteorHeadTime, meteorHeadTime + 0.2f, u.progress));
    float after = g.age > 0.0f ? exp(-g.distance * 90.0f) * exp(-g.age * 7.0f) : 0.0f;
    float headGlow = exp(-length(g.q - head) * 36.0f)
        * (1.0f - transitionSmooth(meteorHeadTime * 0.85f, meteorHeadTime + 0.04f, u.progress));
    float2 cell = floor(g.q * 90.0f);
    float sparkle = g.age > 0.0f
        ? step(0.985f, transitionHash(cell + floor(u.seed * 50.0f))) * exp(-g.distance * 14.0f) * exp(-g.age * 4.0f)
            * (0.5f + 0.5f * sin(u.time * 30.0f + transitionHash(cell) * 6.28f))
        : 0.0f;
    float3 cool = float3(0.72f, 0.86f, 1.0f) * (edge * 0.55f + after * 0.9f + sparkle * 0.9f);
    float3 warm = float3(1.0f, 0.86f, 0.62f) * (trail * 1.1f + headGlow * 1.7f);
    return transitionLight(cool + warm, 0.0f, u.progress);
}

// MARK: - Ink

[[fragment]] float4 wallpaperTransitionInkMask(WallpaperTransitionVertexOut in [[stage_in]],
                                               constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    float2 q = transitionAspect(in.uv, u);
    float2 o = transitionAspect(u.origin, u);
    float r = length(q - o);
    float maxRadius = length(float2(max(o.x, u.aspect - o.x), max(o.y, 1.0f - o.y))) + 0.3f;
    float radius = transitionEaseInOut(u.progress) * maxRadius;
    float n = transitionFBM(q * 2.6f + float2(u.seed * 7.0f, 0.0f) + u.time * 0.04f);
    float n2 = transitionFBM(q * 9.0f + float2(0.0f, u.seed * 3.0f));
    float started = step(0.001f, radius);
    float edgeRadius = radius * (0.72f + 0.56f * n) + (n2 - 0.5f) * 0.05f * started;
    float revealed = transitionSmooth(edgeRadius + 0.012f, edgeRadius - 0.012f, r) * started;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 center = transitionAspect(transitionHash2(float2(fi * 3.7f + u.seed, 1.3f)), u);
        float t0 = 0.12f + 0.16f * fi;
        float dropRadius = transitionEaseInOut((u.progress - t0) / 0.7f) * 0.5f
            * (0.6f + 0.8f * transitionHash(float2(fi, u.seed)));
        float dropEdge = dropRadius * (0.7f + 0.6f * transitionFBM(q * 3.3f + fi * 5.0f));
        float drop = transitionSmooth(dropEdge + 0.01f, dropEdge - 0.01f, length(q - center));
        revealed = max(revealed, drop * step(0.001f, dropRadius));
    }
    revealed = max(revealed, transitionSmooth(0.9f, 1.0f, u.progress));
    return float4(1.0f - revealed);
}

// MARK: - Light leak

static inline float leakOffset(float2 q, constant WallpaperTransitionUniforms &u) {
    float x0 = mix(-0.6f, u.aspect + 0.6f, transitionEaseInOut(u.progress));
    float wobble = 0.12f * sin(q.y * 3.1f + u.time * 1.3f) + 0.06f * sin(q.y * 7.3f - u.time * 2.0f);
    return q.x - (x0 + wobble);
}

[[fragment]] float4 wallpaperTransitionLeakMask(WallpaperTransitionVertexOut in [[stage_in]],
                                                constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    float dx = leakOffset(transitionAspect(in.uv, u), u);
    float revealed = max(transitionSmooth(0.3f, -0.3f, dx), transitionSmooth(0.93f, 1.0f, u.progress));
    return float4(1.0f - revealed);
}

[[fragment]] float4 wallpaperTransitionLeakLight(WallpaperTransitionVertexOut in [[stage_in]],
                                                 constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    float2 q = transitionAspect(in.uv, u);
    float dx = leakOffset(q, u);
    float envelope = transitionSmooth(0.0f, 0.12f, u.progress) * (1.0f - transitionSmooth(0.88f, 1.0f, u.progress));
    float band = exp(-dx * dx * 6.0f) * envelope;
    float exposure = max(sin(u.progress * 3.14159f), 0.0f);
    float3 tint = mix(float3(1.0f, 0.62f, 0.3f), float3(1.0f, 0.45f, 0.42f),
                      0.5f + 0.5f * sin(q.y * 2.0f + u.time * 0.7f));
    return transitionLight(tint * (band * 0.8f + exposure * 0.16f), 0.0f, u.progress);
}

// MARK: - Aurora curtain

static inline float auroraOffset(float2 q, constant WallpaperTransitionUniforms &u) {
    // Starts high enough that the tallest wave crest (0.125) stays above the top edge at progress 0.
    float y0 = mix(1.15f, -0.3f, transitionEaseInOut(u.progress));
    float front = y0 + 0.07f * sin(q.x * 3.3f + u.time * 1.1f) + 0.035f * sin(q.x * 8.1f - u.time * 1.7f)
        + 0.02f * sin(q.x * 17.0f + u.time * 2.3f);
    return q.y - front;
}

[[fragment]] float4 wallpaperTransitionAuroraMask(WallpaperTransitionVertexOut in [[stage_in]],
                                                  constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    float dy = auroraOffset(transitionAspect(in.uv, u), u);
    float revealed = max(transitionSmooth(-0.02f, 0.02f, dy), transitionSmooth(0.93f, 1.0f, u.progress));
    return float4(1.0f - revealed);
}

[[fragment]] float4 wallpaperTransitionAuroraLight(WallpaperTransitionVertexOut in [[stage_in]],
                                                   constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    float2 q = transitionAspect(in.uv, u);
    float dy = auroraOffset(q, u);
    float rays = 0.55f + 0.45f * sin(q.x * 55.0f + transitionFBM(float2(q.x * 6.0f, u.time * 0.5f)) * 6.0f);
    float glow = (dy > 0.0f ? exp(-dy * 6.0f) * rays : 0.0f) + exp(-abs(dy) * 60.0f) * 0.8f;
    float3 tint = mix(float3(0.25f, 1.0f, 0.6f), float3(0.55f, 0.4f, 1.0f), transitionSmooth(0.0f, 0.35f, max(dy, 0.0f)));
    return transitionLight(tint * glow * 0.75f * (1.0f - transitionSmooth(0.8f, 1.0f, u.progress)), 0.0f, u.progress);
}

// MARK: - Weave

struct WeaveRow {
    float row;
    float local;
    float shuttle;
    float x;
};

constant float weaveRows = 36.0f;

static inline WeaveRow weaveRow(float2 uv, constant WallpaperTransitionUniforms &u) {
    WeaveRow w;
    w.row = floor((1.0f - uv.y) * weaveRows);
    w.local = clamp((u.progress - w.row / weaveRows * 0.55f) / 0.4f, 0.0f, 1.0f);
    w.shuttle = mix(-0.05f, u.aspect + 0.05f, transitionEaseInOut(w.local));
    float qx = uv.x * u.aspect;
    w.x = fmod(w.row, 2.0f) < 1.0f ? qx : u.aspect - qx;
    return w;
}

[[fragment]] float4 wallpaperTransitionWeaveMask(WallpaperTransitionVertexOut in [[stage_in]],
                                                 constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    WeaveRow w = weaveRow(in.uv, u);
    float revealed = max(transitionSmooth(w.shuttle + 0.02f, w.shuttle - 0.02f, w.x), transitionSmooth(0.95f, 1.0f, u.progress));
    return float4(1.0f - revealed);
}

[[fragment]] float4 wallpaperTransitionWeaveLight(WallpaperTransitionVertexOut in [[stage_in]],
                                                  constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    WeaveRow w = weaveRow(in.uv, u);
    float lineY = fract((1.0f - in.uv.y) * weaveRows);
    float fresh = w.x < w.shuttle ? exp(-(w.shuttle - w.x) * 6.0f) : 0.0f;
    float fiber = (0.9f + 0.1f * sin(lineY * 3.14159f))
        * (1.0f - 0.06f * step(0.5f, fract(in.uv.x * u.aspect * 90.0f + w.row * 0.5f)));
    float darken = fresh * (1.0f - u.progress) * (1.0f - fiber);
    float shuttle = exp(-abs(w.x - w.shuttle) * 40.0f) * step(0.001f, w.local) * step(w.local, 0.999f)
        * (0.6f + 0.4f * sin(lineY * 3.14159f));
    return transitionLight(float3(1.0f, 0.9f, 0.7f) * shuttle * 0.9f, darken, u.progress);
}
