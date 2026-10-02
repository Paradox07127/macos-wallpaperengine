#include <metal_stdlib>

using namespace metal;

// Mask fragments return how much of the new wallpaper shows: alpha 0 hides it, 1 shows it fully.
// Light fragments return premultiplied colour for a transparent overlay above both the desktop and the
// new wallpaper; they darken only the still-hidden desktop and are fully clear at progress 0 and 1.

struct WallpaperTransitionUniforms {
    float progress;
    float time;
    float aspect;
    float seed;
    float2 origin;
};

struct WallpaperTransitionVertexOut {
    float4 position [[position]];
    float2 uv;
};

static inline float openingSmooth(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

static inline float openingEaseInOut(float x) {
    float t = clamp(x, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

static inline float openingEaseOut(float x) {
    float t = clamp(x, 0.0f, 1.0f);
    return 1.0f - (1.0f - t) * (1.0f - t);
}

static inline float openingHash(float2 p) {
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
}

static inline float openingRoundedBoxDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
}

static inline float2 openingAspect(float2 uv, constant WallpaperTransitionUniforms &u) {
    return float2(uv.x * u.aspect, uv.y);
}

// Screen-blends `light` over the layers below, approximated with one alpha, after darkening them by `darken`.
static inline float4 openingLight(float3 light, float darken) {
    float3 color = clamp(light, 0.0f, 1.0f);
    float glow = max(color.r, max(color.g, color.b));
    float alpha = 1.0f - (1.0f - clamp(darken, 0.0f, 1.0f)) * (1.0f - glow);
    return float4(color, alpha);
}

// MARK: - Loom

constant float loomCenter = 0.5f;

static inline float loomWarpDistance(float2 q, constant WallpaperTransitionUniforms &u) {
    float p = u.progress;
    float vibration = sin(q.x * 6.0f + p * 90.0f) * 0.012f * exp(-max(p - 0.32f, 0.0f) * 18.0f) * step(0.32f, p);
    return q.y - loomCenter - vibration * sin(q.x / u.aspect * M_PI_F);
}

static inline float loomHalfHeight(float p) {
    return openingEaseInOut((p - 0.38f) / 0.5f) * 0.62f;
}

static inline float loomReveal(float2 q, float p) {
    float distance = abs(q.y - loomCenter);
    float row = floor(distance * 80.0f);
    float lag = fmod(row, 2.0f) < 1.0f ? 0.0f : 0.035f;
    float jitter = (openingHash(float2(row, floor(q.x * 20.0f))) - 0.5f) * 0.02f;
    float edge = loomHalfHeight(p) - lag + jitter;
    float revealed = p > 0.38f ? openingSmooth(edge + 0.006f, edge - 0.006f, distance) : 0.0f;
    return max(revealed, openingSmooth(0.93f, 1.0f, p));
}

[[fragment]] float4 wallpaperOpeningLoomMask(WallpaperTransitionVertexOut in [[stage_in]],
                                             constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    return float4(loomReveal(openingAspect(in.uv, u), u.progress));
}

[[fragment]] float4 wallpaperOpeningLoomLight(WallpaperTransitionVertexOut in [[stage_in]],
                                              constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    float2 q = openingAspect(in.uv, u);
    float p = u.progress;
    float dim = openingSmooth(0.0f, 0.12f, p) * (1.0f - openingSmooth(0.55f, 0.8f, p));
    float headX = mix(-0.1f, u.aspect + 0.1f, openingEaseOut((p - 0.1f) / 0.22f));
    float warp = loomWarpDistance(q, u);
    float started = step(0.1f, p);
    float line = exp(-abs(warp) * 260.0f) * step(q.x, headX) * started * (1.0f - openingSmooth(0.38f, 0.5f, p));
    float head = exp(-length(float2(q.x - headX, warp)) * 40.0f) * started * (1.0f - openingSmooth(0.3f, 0.34f, p));
    float fronts = exp(-abs(abs(q.y - loomCenter) - loomHalfHeight(p)) * 120.0f) * step(0.38f, p)
        * (1.0f - openingSmooth(0.8f, 0.95f, p));
    float3 light = float3(0.72f, 0.84f, 1.0f) * (line * 1.2f + head * 1.8f + fronts * 0.8f);
    return openingLight(light, 0.45f * dim * (1.0f - loomReveal(q, p)));
}

// MARK: - Frame

struct FrameGeometry {
    float2 center;
    float distance;
};

constant float frameHalfSize = 0.13f;
constant float frameRadius = 0.035f;

static inline float2 frameRestCenter(constant WallpaperTransitionUniforms &u) {
    return float2(u.aspect * 0.5f + 0.02f, 0.52f);
}

static inline FrameGeometry frameGeometry(float2 q, constant WallpaperTransitionUniforms &u) {
    float expand = openingEaseInOut((u.progress - 0.48f) / 0.4f);
    float2 halfSize = mix(float2(frameHalfSize), float2(u.aspect * 0.5f + 0.08f, 0.58f), expand);
    FrameGeometry g;
    g.center = frameRestCenter(u);
    float2 center = mix(g.center, float2(u.aspect * 0.5f, 0.5f), expand);
    g.distance = openingRoundedBoxDistance(q - center, halfSize, mix(frameRadius, 0.0f, expand));
    return g;
}

static inline float frameReveal(FrameGeometry g, float p) {
    return max(openingSmooth(0.003f, -0.003f, g.distance) * openingSmooth(0.18f, 0.32f, p), openingSmooth(0.93f, 1.0f, p));
}

[[fragment]] float4 wallpaperOpeningFrameMask(WallpaperTransitionVertexOut in [[stage_in]],
                                              constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    return float4(frameReveal(frameGeometry(openingAspect(in.uv, u), u), u.progress));
}

[[fragment]] float4 wallpaperOpeningFrameLight(WallpaperTransitionVertexOut in [[stage_in]],
                                               constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    float2 q = openingAspect(in.uv, u);
    float p = u.progress;
    FrameGeometry g = frameGeometry(q, u);
    float dim = openingSmooth(0.0f, 0.1f, p) * 0.55f * (1.0f - openingSmooth(0.6f, 0.85f, p));
    // Angle runs clockwise from straight up, so the stroke is drawn from 12 o'clock.
    float2 fromCenter = q - g.center;
    float angle = fract(atan2(fromCenter.x, fromCenter.y) / (2.0f * M_PI_F) + 1.0f);
    float drawn = max(step(angle, openingEaseOut((p - 0.08f) / 0.28f)), openingSmooth(0.36f, 0.4f, p));
    float stroke = exp(-abs(g.distance) * 300.0f) * drawn * step(0.08f, p) * (1.0f - openingSmooth(0.55f, 0.85f, p));
    float slide = openingSmooth(0.3f, 0.45f, p);
    float backDistance = openingRoundedBoxDistance(q - (g.center + float2(-0.045f) * slide), float2(frameHalfSize), frameRadius);
    // The back frame only shows where it sticks out past the front frame's lower-left edges.
    float hidden = step(g.center.x - frameHalfSize + 0.012f, q.x) * step(g.center.y - frameHalfSize + 0.012f, q.y);
    float back = exp(-abs(backDistance) * 300.0f) * (1.0f - hidden) * slide * (1.0f - openingSmooth(0.5f, 0.62f, p));
    float3 light = float3(0.85f, 0.9f, 1.0f) * stroke * 1.1f + float3(0.36f, 0.52f, 1.0f) * back;
    return openingLight(light, dim * (1.0f - frameReveal(g, p)));
}

// MARK: - Dawn

constant float dawnHorizon = 0.34f;

static inline float dawnRise(float p) {
    return openingEaseInOut((p - 0.32f) / 0.5f);
}

static inline float dawnReveal(float2 q, constant WallpaperTransitionUniforms &u) {
    float p = u.progress;
    float spread = dawnRise(p) * 1.3f;
    float distance = abs(q.y - dawnHorizon) + 0.03f * sin(q.x * 4.0f + u.time * 0.8f);
    return max(openingSmooth(spread + 0.1f, spread - 0.1f, distance) * openingSmooth(0.3f, 0.38f, p), openingSmooth(0.93f, 1.0f, p));
}

[[fragment]] float4 wallpaperOpeningDawnMask(WallpaperTransitionVertexOut in [[stage_in]],
                                             constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    return float4(dawnReveal(openingAspect(in.uv, u), u));
}

[[fragment]] float4 wallpaperOpeningDawnLight(WallpaperTransitionVertexOut in [[stage_in]],
                                              constant WallpaperTransitionUniforms &u [[buffer(0)]]) {
    float2 q = openingAspect(in.uv, u);
    float p = u.progress;
    float revealed = dawnReveal(q, u);
    float dark = openingSmooth(0.0f, 0.22f, p) * (1.0f - openingSmooth(0.45f, 0.75f, p));
    float horizonDistance = abs(q.y - dawnHorizon);
    float horizon = exp(-horizonDistance * 140.0f) * openingSmooth(0.2f, 0.3f, p) * (1.0f - openingSmooth(0.5f, 0.7f, p))
        * (0.6f + 0.4f * exp(-abs(q.x - u.aspect * 0.5f) * 1.2f));
    float sky = exp(-horizonDistance * 5.0f) * 0.35f * dawnRise(p) * (1.0f - openingSmooth(0.7f, 1.0f, p));
    // Stands in for the prototype's to * (1 + exposure): a fading warm white over the revealed wallpaper.
    float exposure = (1.0f - openingSmooth(0.4f, 0.8f, p)) * 0.9f * revealed;
    float3 light = float3(1.0f, 0.72f, 0.42f) * (horizon * 1.2f + sky) + float3(1.0f, 0.95f, 0.86f) * exposure * 0.6f;
    return openingLight(light, 0.92f * dark * (1.0f - revealed));
}
