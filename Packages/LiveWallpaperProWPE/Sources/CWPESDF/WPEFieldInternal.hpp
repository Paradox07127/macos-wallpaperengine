#pragma once

#include "include/CWPESDF.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace wpe_field {

inline bool validOutput(const WPEFieldOutput *out, size_t channels) {
    if (!out || out->width <= 0 || out->height <= 0 || out->width > 4096 || out->height > 4096)
        return false;
    const size_t pixels = size_t(out->width) * size_t(out->height);
    const auto validStage = [pixels, channels](const float *p, size_t capacity) {
        return p ? capacity >= pixels * channels : capacity == 0;
    };
    return out->rgba && out->rgba_capacity >= pixels * 4 &&
        validStage(out->before_correction, out->before_capacity) &&
        validStage(out->after_correction, out->after_capacity);
}

inline bool validTransform(const WPEFieldTransform *t) {
    return t && std::isfinite(t->scale_x) && t->scale_x > 0 &&
        std::isfinite(t->scale_y) && t->scale_y > 0 &&
        std::isfinite(t->translate_x) && std::isfinite(t->translate_y) &&
        std::isfinite(t->distance_scale) && t->distance_scale > 0 &&
        std::isfinite(t->distance_offset) && t->distance_offset > 0;
}

/// CVTTSS2SI returns integer-indefinite on NaN/overflow; original then clamps that signed int to 0...255.
inline uint8_t quantize(float value) {
    const float scaled = value * 256.f;
    int32_t integer = std::numeric_limits<int32_t>::min();
    if (std::isfinite(scaled) && scaled >= -2147483648.f && scaled < 2147483648.f)
        integer = int32_t(scaled);
    return uint8_t(std::max(0, std::min(255, integer)));
}

inline void quantizeRows(const float *field, const WPEFieldOutput &out, size_t channels) {
    for (int y = 0; y < out.height; ++y) {
        const float *src = field + size_t(out.height - y - 1) * out.width * channels;
        uint8_t *dst = out.rgba + size_t(y) * out.width * 4;
        for (int x = 0; x < out.width; ++x) {
            for (size_t c = 0; c < channels; ++c)
                dst[4 * x + c] = quantize(src[channels * x + c]);
            if (channels == 3)
                dst[4 * x + 3] = 255;
        }
    }
}

}
