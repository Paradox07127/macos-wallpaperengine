#include <metal_stdlib>
using namespace metal;


constant bool wpe_unorm_target [[function_constant(1023)]];
inline float4 wpe_attachment_output(float4 color) {
    return is_function_constant_defined(wpe_unorm_target) && wpe_unorm_target ? saturate(color) : color;
}
inline float4 wpe_native_sample(float4 color) { return color; }
inline float4 wpe_native_sample(half4 color) { return float4(color); }

struct WPEVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct WPEPresentUniforms {
    float2 ndcScale;
    float2 uvScale;
    float2 uvOffset;
    float2 ndcOffset;
};

struct WPEVideoYCbCrUniforms {
    float3x3 colorMatrix;
    float3 offset;
};

[[vertex]] WPEVertexOut wpe_fullscreen_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    WPEVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

[[vertex]] WPEVertexOut wpe_present_vertex(
    uint vertexID [[vertex_id]],
    constant WPEPresentUniforms& u [[buffer(0)]]
) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    WPEVertexOut out;
    out.position = float4(positions[vertexID] * u.ndcScale + u.ndcOffset, 0.0, 1.0);
    out.uv = uvs[vertexID] * u.uvScale + u.uvOffset;
    return out;
}

static inline float3 wpe_authored_rgb_to_linear(float3 color) {
    color = max(color, float3(0.0));
    return select(pow((color + 0.055) / 1.055, float3(2.4)),
                  color / 12.92, color <= 0.04045);
}

[[fragment]] half4 wpe_present_authored_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<float, access::sample> texture0 [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return half4(wpe_attachment_output(float4(half4(float4(wpe_authored_rgb_to_linear(wpe_native_sample(texture0.sample(linearSampler, in.uv)).rgb), 1.0)))));
}

[[fragment]] half4 wpe_present_hdr_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<float, access::sample> texture0 [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float3 color = wpe_native_sample(texture0.sample(linearSampler, in.uv)).rgb;
    return half4(wpe_attachment_output(float4(half4(float4(saturate(wpe_authored_rgb_to_linear(color)), 1.0)))));
}

[[fragment]] float4 wpe_present_linear_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<float, access::sample> texture0 [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return float4(texture0.sample(linearSampler, in.uv).rgb, 1.0);
}

[[fragment]] half4 wpe_video_nv12_convert_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    constant WPEVideoYCbCrUniforms& conversion [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float3 ycbcr = float3(
        wpe_native_sample(luma.sample(linearSampler, in.uv)).r,
        chroma.sample(linearSampler, in.uv).rg
    );
    float3 rgb = clamp(conversion.colorMatrix * (ycbcr - conversion.offset), 0.0, 1.0);
    return half4(wpe_attachment_output(float4(half4(half3(rgb), 1.0h))));
}
