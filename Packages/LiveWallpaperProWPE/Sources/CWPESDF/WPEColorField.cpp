#include "WPEFieldInternal.hpp"
#include <new>
#include <vector>

namespace {

constexpr float farDistance = 1.e20f; // Original bits 0x60ad78ec; finite, not infinity.

struct DistanceScratch {
    std::vector<int> sites;
    std::vector<float> boundaries, values, column;
    explicit DistanceScratch(int length)
        : sites(length), boundaries(length + 1), values(length), column(length) { }
};

// Original 1401ac130. Breakpoints remain float32; decompiler's uint cast at MOVSS is not a conversion.
void transformLine(float *f, int count, DistanceScratch &s) {
    int k = 0;
    s.sites[0] = 0;
    s.boundaries[0] = -farDistance;
    s.boundaries[1] = farDistance;
    for (int q = 1; q < count; ++q) {
        const float fq = float(q) * float(q) + f[q];
        auto intersection = [&](int v) {
            return (fq - (float(v) * float(v) + f[v])) / float((q - v) * 2);
        };
        float at = intersection(s.sites[k]);
        while (at <= s.boundaries[k]) at = intersection(s.sites[--k]);
        ++k;
        s.sites[k] = q;
        s.boundaries[k] = at;
        s.boundaries[k + 1] = farDistance;
    }
    k = 0;
    for (int q = 0; q < count; ++q) {
        while (float(q) > s.boundaries[k + 1]) ++k;
        const int delta = q - s.sites[k];
        s.values[q] = float(delta * delta) + f[s.sites[k]];
    }
    std::copy_n(s.values.data(), count, f);
}

// Original 1401ac3b0: columns first, then contiguous rows. Scratch lives only in this borrowed call.
void transformPlane(std::vector<float> &plane, int width, int rows, DistanceScratch &s) {
    for (int x = 0; x < width; ++x) {
        for (int y = 0; y < rows; ++y) s.column[y] = plane[size_t(y) * width + x];
        transformLine(s.column.data(), rows, s);
        for (int y = 0; y < rows; ++y) plane[size_t(y) * width + x] = s.column[y];
    }
    for (int y = 0; y < rows; ++y) transformLine(plane.data() + size_t(y) * width, width, s);
}

bool validBitmap(const WPEFieldBGRA *b) {
    if (!b || !b->bytes || b->width <= 0 || b->rows <= 0 || b->width > 4096 || b->rows > 4096)
        return false;
    const int64_t rowBytes = int64_t(b->width) * 4;
    const int64_t pitch = b->pitch;
    if (std::abs(pitch) < rowBytes || b->row0_offset > b->capacity ||
        b->capacity > size_t(std::numeric_limits<int64_t>::max())) return false;
    const int64_t start = int64_t(b->row0_offset);
    const int64_t end = start + int64_t(b->rows - 1) * pitch;
    return std::min(start, end) >= 0 && std::max(start, end) <= int64_t(b->capacity) - rowBytes;
}

}

extern "C" WPEFieldStatus wpe_field_color(const WPEFieldBGRA *b, const WPEFieldTransform *t,
                                          const WPEFieldOutput *out) {
    if (!validBitmap(b) || !wpe_field::validTransform(t) || !wpe_field::validOutput(out, 4) ||
        out->before_correction || out->before_capacity ||
        t->distance_scale != 1. / (t->distance_offset * 2.)) return WPE_FIELD_INVALID_INPUT;
    try {
        const size_t pixels = size_t(b->width) * b->rows;
        std::vector<float> inside(pixels), outside(pixels);
        for (int y = 0; y < b->rows; ++y) {
            const uint8_t *row = b->bytes + int64_t(b->row0_offset) + int64_t(y) * b->pitch;
            for (int x = 0; x < b->width; ++x) {
                const size_t i = size_t(y) * b->width + x;
                const bool covered = row[x * 4 + 3] >= 128;
                inside[i] = covered ? 0 : farDistance;
                outside[i] = covered ? farDistance : 0;
            }
        }
        DistanceScratch scratch(std::max(b->width, b->rows));
        transformPlane(inside, b->width, b->rows, scratch);
        transformPlane(outside, b->width, b->rows, scratch);
        // Reuse the first plane for signed distances; no independent field/atlas cache.
        for (int y = 0; y < b->rows; ++y) {
            const uint8_t *row = b->bytes + int64_t(b->row0_offset) + int64_t(y) * b->pitch;
            for (int x = 0; x < b->width; ++x) {
                const size_t i = size_t(y) * b->width + x;
                inside[i] = row[x * 4 + 3] < 128 ? -std::sqrt(inside[i]) + .5f
                                               : std::sqrt(outside[i]) - .5f;
            }
        }
        // Native caller's range is float32; helper computes double reciprocal then narrows once.
        const float inverseRange = float(t->distance_scale);
        std::vector<float> field(size_t(out->width) * out->height * 4);
        for (int y = 0; y < out->height; ++y) {
            const float py = float((double(y) + .5) / t->scale_y - t->translate_y);
            const float sy = float(b->top) - py;
            const float cy = std::max(0.f, std::min(float(b->rows - 1), sy));
            const float floorY = std::floor(cy), fy = cy - floorY;
            const int y0 = int(floorY), y1 = std::min(y0 + 1, b->rows - 1);
            for (int x = 0; x < out->width; ++x) {
                const float sx = float((double(x) + .5) / t->scale_x - t->translate_x) - float(b->left);
                const float cx = std::max(0.f, std::min(float(b->width - 1), sx));
                const float floorX = std::floor(cx), fx = cx - floorX, gx = 1.f - fx;
                const int x0 = int(floorX), x1 = std::min(x0 + 1, b->width - 1);
                const float upper = gx * inside[size_t(y0) * b->width + x0] +
                                    fx * inside[size_t(y0) * b->width + x1];
                const float lower = gx * inside[size_t(y1) * b->width + x0] +
                                    fx * inside[size_t(y1) * b->width + x1];
                const float dy = sy - cy, dx = sx - cx;
                const float rectangleDistance = std::sqrt(dy * dy + dx * dx);
                const float value = ((upper * (1.f - fy) + lower * fy) - rectangleDistance) * inverseRange + .5f;
                float *pixel = field.data() + (size_t(y) * out->width + x) * 4;
                std::fill_n(pixel, 4, value);
            }
        }
        if (out->after_correction) std::copy(field.begin(), field.end(), out->after_correction);
        wpe_field::quantizeRows(field.data(), *out, 4);
        return WPE_FIELD_OK;
    } catch (const std::bad_alloc &) {
        return WPE_FIELD_ALLOCATION_FAILED;
    } catch (...) {
        return WPE_FIELD_GENERATION_FAILED;
    }
}

extern "C" WPEFieldStatus wpe_field_color_companion(const WPEFieldBGRA *b,
                                                   const WPEFieldTransform *t,
                                                   int32_t companionScale,
                                                   const WPEFieldOutput *out) {
    if ((companionScale != 1 && companionScale != 2) || !validBitmap(b) ||
        !wpe_field::validTransform(t) || !wpe_field::validOutput(out, 4) ||
        out->before_correction || out->before_capacity || out->after_correction || out->after_capacity)
        return WPE_FIELD_INVALID_INPUT;
    // 1401ae080 narrows colourScale * fieldScale to float32 before the double pixel-centre division.
    // Only same-call scales 1/2 are qualified here; the caller still owns first-glyph group selection.
    const double scaleX = double(float(companionScale) * float(t->scale_x));
    const double scaleY = double(float(companionScale) * float(t->scale_y));
    if (!std::isfinite(scaleX) || !std::isfinite(scaleY) || scaleX <= 0 || scaleY <= 0)
        return WPE_FIELD_INVALID_INPUT;
    for (int y = 0; y < out->height; ++y) {
        const float sy = float(b->top) - float((double(out->height - y - 1) + .5) / scaleY - t->translate_y);
        for (int x = 0; x < out->width; ++x) {
            uint8_t *pixel = out->rgba + (size_t(y) * out->width + x) * 4;
            const float sx = float((double(x) + .5) / scaleX - t->translate_x) - float(b->left);
            if (sx < 0 || sx > float(b->width - 1) || sy < 0 || sy > float(b->rows - 1)) {
                std::fill_n(pixel, 4, 0);
                continue;
            }
            const float floorX = std::floor(sx), floorY = std::floor(sy);
            const int x0 = int(floorX), y0 = int(floorY);
            const int x1 = std::min(x0 + 1, b->width - 1), y1 = std::min(y0 + 1, b->rows - 1);
            const float fx = sx - floorX, fy = sy - floorY, gx = 1.f - fx, gy = 1.f - fy;
            const float weights[] = {gy * fx, gy * gx, gx * fy, fy * fx};
            const uint8_t *row0 = b->bytes + int64_t(b->row0_offset) + int64_t(y0) * b->pitch;
            const uint8_t *row1 = b->bytes + int64_t(b->row0_offset) + int64_t(y1) * b->pitch;
            for (int channel = 0; channel < 4; ++channel) {
                const int sourceChannel = channel == 0 ? 2 : channel == 2 ? 0 : channel;
                // Native TR, TL, BL, BR order with separate float32 multiply/add, then +.5/CVTT/clamp.
                float value = float(row0[x1 * 4 + sourceChannel]) * weights[0];
                value += float(row0[x0 * 4 + sourceChannel]) * weights[1];
                value += float(row1[x0 * 4 + sourceChannel]) * weights[2];
                value += float(row1[x1 * 4 + sourceChannel]) * weights[3];
                const int quantized = int(value + .5f);
                pixel[channel] = uint8_t(std::max(0, std::min(255, quantized)));
            }
        }
    }
    return WPE_FIELD_OK;
}

extern "C" WPEFieldStatus wpe_field_color_companion_scale_one(const WPEFieldBGRA *b,
                                                             const WPEFieldTransform *t,
                                                             const WPEFieldOutput *out) {
    return wpe_field_color_companion(b, t, 1, out);
}
