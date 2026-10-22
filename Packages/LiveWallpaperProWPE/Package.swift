// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// External producer/oracle acceptance is explicit and never inherited by the mandatory gate.
let externalCorpus = ProcessInfo.processInfo.environment["LIVEWALLPAPER_EXTERNAL_FIXTURES"] == "1"

let package = Package(
    name: "LiveWallpaperProWPE",
    platforms: [.macOS("14.6")],
    products: [
        .library(name: "LiveWallpaperProWPE", targets: ["LiveWallpaperProWPE"]),
    ],
    dependencies: [
        .package(name: "LiveWallpaperCore", path: "../LiveWallpaperCore"),
    ],
    targets: [
        .target(
            name: "LiveWallpaperProWPE",
            dependencies: [
                .product(name: "LiveWallpaperCore", package: "LiveWallpaperCore"),
                "CFreeType",
                "CHarfBuzz",
                "CWPESDF",
            ],
            path: "Sources/LiveWallpaperProWPE",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // FreeType 2.14.3, default ftoption.h + HarfBuzz autofit; the default module set of docs/INSTALL.ANY.
        // Its hb_* references resolve against CHarfBuzz at final link, so never link it without CHarfBuzz.
        .target(
            name: "CFreeType",
            path: "Sources/CFreeType",
            sources: [
                "src/base/ftsystem.c",
                "src/base/ftinit.c",
                "src/base/ftdebug.c",
                "src/base/ftbase.c",
                "src/base/ftbbox.c",
                "src/base/ftbdf.c",
                "src/base/ftbitmap.c",
                "src/base/ftcid.c",
                "src/base/ftfstype.c",
                "src/base/ftgasp.c",
                "src/base/ftglyph.c",
                "src/base/ftgxval.c",
                "src/base/ftmm.c",
                "src/base/ftotval.c",
                "src/base/ftpatent.c",
                "src/base/ftpfr.c",
                "src/base/ftstroke.c",
                "src/base/ftsynth.c",
                "src/base/fttype1.c",
                "src/base/ftwinfnt.c",
                "src/bdf/bdf.c",
                "src/cff/cff.c",
                "src/cid/type1cid.c",
                "src/pcf/pcf.c",
                "src/pfr/pfr.c",
                "src/sfnt/sfnt.c",
                "src/truetype/truetype.c",
                "src/type1/type1.c",
                "src/type42/type42.c",
                "src/winfonts/winfnt.c",
                "src/smooth/smooth.c",
                "src/raster/raster.c",
                "src/sdf/sdf.c",
                "src/svg/svg.c",
                "src/autofit/autofit.c",
                "src/cache/ftcache.c",
                "src/gzip/ftgzip.c",
                "src/lzw/ftlzw.c",
                "src/bzip2/ftbzip2.c",
                "src/psaux/psaux.c",
                "src/pshinter/pshinter.c",
                "src/psnames/psnames.c",
            ],
            cSettings: [
                .define("FT2_BUILD_LIBRARY"),
                .define("FT_CONFIG_OPTION_USE_HARFBUZZ"),
                // Upstream code floods the build with -Wshorten-64-to-32 on LP64.
                .unsafeFlags(["-w"]),
            ]
        ),
        // HarfBuzz 14.2.0 amalgamation with the FreeType font funcs; no CoreText shaper.
        .target(
            name: "CHarfBuzz",
            dependencies: ["CFreeType"],
            path: "Sources/CHarfBuzz",
            sources: ["src/harfbuzz.cc"],
            cxxSettings: [
                .define("HAVE_FREETYPE", to: "1"),
                .define("HAVE_FT_GET_VAR_BLEND_COORDINATES", to: "1"),
                .define("HAVE_FT_DONE_MM_VAR", to: "1"),
                .define("HAVE_FT_GET_TRANSFORM", to: "1"),
            ]
        ),
        // Pinned msdfgen 1.13 core. Borrows the existing FreeType outline; no second font or atlas owner.
        .target(
            name: "CWPESDF",
            dependencies: ["CFreeType"],
            path: "Sources/CWPESDF",
            exclude: ["vendor/msdfgen/LICENSE.txt", "vendor/msdfgen/SOURCE.json"],
            sources: ["WPEField.cpp", "WPEColorField.cpp", "vendor/msdfgen/core"],
            cxxSettings: [
                .define("MSDFGEN_PUBLIC", to: ""),
                .define("MSDFGEN_USE_CPP11"),
                .unsafeFlags(["-ffp-contract=off", "-fno-fast-math"]),
            ]
        ),
        .testTarget(
            name: "LiveWallpaperProWPETests",
            dependencies: ["LiveWallpaperProWPE", "CHarfBuzz", "CFreeType", "CWPESDF"],
            path: "Tests/LiveWallpaperProWPETests",
            exclude: externalCorpus ? [] : ["ExternalCorpus"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
