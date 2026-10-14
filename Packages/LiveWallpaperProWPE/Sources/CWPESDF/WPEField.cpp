#include "WPEFieldInternal.hpp"
#include "vendor/msdfgen/msdfgen.h"
#include <new>
#include <vector>

namespace {

// Adapted from pinned v1.13 ext/import-font.cpp's outline callbacks only. No loadGlyph/NO_SCALE/font owner.
struct OutlineContext {
    msdfgen::Shape &shape;
    msdfgen::Contour *contour = nullptr;
    msdfgen::Point2 position;
};

msdfgen::Point2 point(const FT_Vector *p) {
    return msdfgen::Point2((1 / 64.) * double(p->x), (1 / 64.) * double(p->y));
}

int moveTo(const FT_Vector *to, void *user) {
    auto &c = *static_cast<OutlineContext *>(user);
    if (!(c.contour && c.contour->edges.empty())) c.contour = &c.shape.addContour();
    c.position = point(to);
    return 0;
}

int lineTo(const FT_Vector *to, void *user) {
    auto &c = *static_cast<OutlineContext *>(user);
    const auto end = point(to);
    if (end != c.position) {
        c.contour->addEdge(msdfgen::EdgeHolder(c.position, end));
        c.position = end;
    }
    return 0;
}

int conicTo(const FT_Vector *control, const FT_Vector *to, void *user) {
    auto &c = *static_cast<OutlineContext *>(user);
    const auto end = point(to);
    if (end != c.position) {
        c.contour->addEdge(msdfgen::EdgeHolder(c.position, point(control), end));
        c.position = end;
    }
    return 0;
}

int cubicTo(const FT_Vector *a, const FT_Vector *b, const FT_Vector *to, void *user) {
    auto &c = *static_cast<OutlineContext *>(user);
    const auto end = point(to);
    if (end != c.position || msdfgen::crossProduct(point(a) - end, point(b) - end)) {
        c.contour->addEdge(msdfgen::EdgeHolder(c.position, point(a), point(b), end));
        c.position = end;
    }
    return 0;
}

}

extern "C" WPEFieldStatus wpe_field_outline(FT_Outline *outline, const WPEFieldTransform *t,
                                            const WPEFieldOutput *out) {
    if (!wpe_field::validOutput(out, 3) || !wpe_field::validTransform(t) || !outline)
        return WPE_FIELD_INVALID_INPUT;
    // Native offset is minus the symmetric interval's lower endpoint. Preserve its exact six-double mapping.
    const msdfgen::Range range(-t->distance_offset, t->distance_offset);
    const msdfgen::DistanceMapping mapping(range);
    if (mapping(msdfgen::DistanceMapping::Delta(1)) != t->distance_scale)
        return WPE_FIELD_INVALID_INPUT;
    if (FT_Outline_Check(outline) != 0 || outline->n_contours <= 0 || outline->n_points <= 0)
        return WPE_FIELD_INVALID_OUTLINE;
    try {
        msdfgen::Shape shape;
        shape.setYAxisOrientation(msdfgen::Y_UPWARD);
        OutlineContext context{shape};
        const FT_Outline_Funcs callbacks{moveTo, lineTo, conicTo, cubicTo, 0, 0};
        if (FT_Outline_Decompose(outline, &callbacks, &context) != 0)
            return WPE_FIELD_INVALID_OUTLINE;
        if (!shape.contours.empty() && shape.contours.back().edges.empty()) shape.contours.pop_back();
        if (!shape.validate() || shape.contours.empty()) return WPE_FIELD_INVALID_OUTLINE;
        shape.normalize();
        shape.orientContours();
        msdfgen::edgeColoringSimple(shape, 3., 0);

        const size_t samples = size_t(out->width) * out->height * 3;
        std::vector<float> field(samples);
        msdfgen::BitmapSection<float, 3> bitmap(field.data(), out->width, out->height,
                                               msdfgen::Y_UPWARD);
        const msdfgen::SDFTransformation transform(
            msdfgen::Projection(msdfgen::Vector2(t->scale_x, t->scale_y),
                                msdfgen::Vector2(t->translate_x, t->translate_y)), mapping);
        // Public generateMSDF corrects internally. Disable that pass so pre/post observations share one generation.
        const msdfgen::MSDFGeneratorConfig generateConfig(true,
            msdfgen::ErrorCorrectionConfig(msdfgen::ErrorCorrectionConfig::DISABLED));
        msdfgen::generateMSDF(bitmap, shape, transform, generateConfig);
        if (out->before_correction) std::copy(field.begin(), field.end(), out->before_correction);
        const msdfgen::MSDFGeneratorConfig correction(true, msdfgen::ErrorCorrectionConfig(
            msdfgen::ErrorCorrectionConfig::EDGE_PRIORITY,
            msdfgen::ErrorCorrectionConfig::CHECK_DISTANCE_AT_EDGE,
            1.1111111111111112, 1.1111111111111112, nullptr));
        msdfgen::msdfErrorCorrection(bitmap, shape, transform, correction);
        if (out->after_correction) std::copy(field.begin(), field.end(), out->after_correction);
        wpe_field::quantizeRows(field.data(), *out, 3);
        return WPE_FIELD_OK;
    } catch (const std::bad_alloc &) {
        return WPE_FIELD_ALLOCATION_FAILED;
    } catch (...) {
        return WPE_FIELD_GENERATION_FAILED;
    }
}
