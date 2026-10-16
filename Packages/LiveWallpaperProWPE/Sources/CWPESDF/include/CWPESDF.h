#ifndef CWPESDF_H
#define CWPESDF_H

#include <stddef.h>
#include <stdint.h>
#include <ft2build.h>
#include FT_OUTLINE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum WPEFieldStatus {
    WPE_FIELD_OK = 0,
    WPE_FIELD_INVALID_INPUT = 1,
    WPE_FIELD_INVALID_OUTLINE = 2,
    WPE_FIELD_ALLOCATION_FAILED = 3,
    WPE_FIELD_GENERATION_FAILED = 4
} WPEFieldStatus;

/// Original six-double SDFTransformation: (distance + distance_offset) * distance_scale.
typedef struct WPEFieldTransform {
    double scale_x, scale_y;
    double translate_x, translate_y;
    double distance_scale, distance_offset;
} WPEFieldTransform;

/// Caller-owned output. RGBA rows are top first; optional float stages are y-up (native generator order).
/// A stage pointer must be null with capacity zero, or hold width * height * channels floats.
/// No pointers are retained. Neither entry point opens a font or owns an atlas.
typedef struct WPEFieldOutput {
    int32_t width, height;
    uint8_t *rgba;
    size_t rgba_capacity;
    float *before_correction;
    size_t before_capacity;
    float *after_correction;
    size_t after_capacity;
} WPEFieldOutput;

/// Borrows an already FT_LOAD_NO_BITMAP-loaded, size-qualified 26.6 outline synchronously.
/// normalize -> orientContours -> Simple(angle 3, seed 0) -> overlap RGB -> one edge-priority correction.
WPEFieldStatus wpe_field_outline(FT_Outline *outline, const WPEFieldTransform *transform,
                                const WPEFieldOutput *output);

/// BGRA buffer is a bounded allocation; row0_offset identifies its logical top row for signed pitch.
typedef struct WPEFieldBGRA {
    const uint8_t *bytes;
    size_t capacity, row0_offset;
    int32_t width, rows, pitch;
    int32_t left, top;
} WPEFieldBGRA;

/// Native COLOR alpha >= 128 two-plane float32 EDT, not shape MTSDF. All four field channels are equal.
/// before_correction is unused and must be null; after_correction optionally receives y-up float4.
WPEFieldStatus wpe_field_color(const WPEFieldBGRA *bitmap, const WPEFieldTransform *transform,
                              const WPEFieldOutput *output);

/// 1401ac4e0 companion at colour scale 1 or 2: top-first premultiplied RGBA, no quantizer. Output size is the
/// primary's cell size times companion_scale; float stages must be null.
WPEFieldStatus wpe_field_color_companion(const WPEFieldBGRA *bitmap,
                                        const WPEFieldTransform *transform, int32_t companion_scale,
                                        const WPEFieldOutput *output);

/// Retained scale-one ABI; forwards to the same resampler with companion_scale=1.
WPEFieldStatus wpe_field_color_companion_scale_one(const WPEFieldBGRA *bitmap,
                                                  const WPEFieldTransform *transform,
                                                  const WPEFieldOutput *output);

#ifdef __cplusplus
}
#endif
#endif
