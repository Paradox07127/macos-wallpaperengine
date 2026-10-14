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
