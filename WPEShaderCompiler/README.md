# WPE shader compiler helper

`wpe-shaderc` is a C++17, arm64 helper targeting macOS 14.6. It loads DXC and
Metal Shader Converter (MSC) with `dlopen`; neither library is linked into the
helper or the app. Its runtime produces metallib bytes directly through MSC;
it does not require Xcode, `dxc`, `metal-shaderconverter` or a Metal compiler CLI
on the user's machine.

## Pinned build inputs

Set `WPE_SHADER_TOOLCHAIN_ROOT` explicitly to an input directory. There is no
installation-path or developer-home default. `toolchain-inputs.sha256` pins
30 files relative to that directory: 24 headers, two libraries and four complete
notices. `build.sh` verifies every pin before compiling the current `main.cpp`
with the selected Xcode SDK's `clang++`; it does not copy a prebuilt helper.

```text
include/dxc/                    dxcapi.h, WinAdapter.h
include/directx/                d3d12shader.h, d3dcommon.h
include/wsl/stubs/              rpc.h, rpcndr.h, OAIdl.h, OCIdl.h
include/metal_irconverter/      metal_irconverter.h and its 15 ir_*.h includes
lib/                           libdxcompiler.dylib, libmetalirconverter.dylib
licenses/                      DXC-LICENSE.TXT, DirectX-Headers-LICENSE,
                               MSC-LICENSE.txt, MSC-Acknowledgements.rtf
```

The pinned DXC inputs come from v1.9.2609, source commit
`01b62ad47db7dee3dd33f90e7339cf9e860b3f93`, with DirectX-Headers submodule
`980971e835876dc0cde415e8f9bc646e64667bf7`. The library is arm64 with minimum
macOS 14.6. Its recorded build used Release, assertions/tests disabled and
`CMAKE_OSX_ARCHITECTURES=arm64`, `CMAKE_OSX_DEPLOYMENT_TARGET=14.6`.

The pinned MSC inputs are the installed SDK with headers declaring 4.0.1.
The installer receipt is `com.apple.metal`, package version
`1.0.1.1784657527`, installed 2026-10-12 06:27:17 UTC; the receipt attributes
the library, version header and acknowledgements to that same package. The
library contains arm64 and x86_64 slices with minimum macOS 13.0. The original
installer archive hash is not recorded, and the opaque receipt version is not
a claim about a binary semantic-version string. Exact input bytes are pinned
independently of this provenance metadata.

Populate the layout from those inputs, preserving the original notice files.
The SHA list gives the full file inventory. For an already prepared directory:

```sh
export WPE_SHADER_TOOLCHAIN_ROOT="$PWD/build/wpe-shader-toolchain-inputs"
bash WPEShaderCompiler/build.sh "$PWD/build/wpe-shaderc"
```

Omitting the output directory uses ignored `WPEShaderCompiler/build/`. Build
output records the compiler/SDK versions and source, pin-list and output hashes.
The fixed recipe is C++17, `-O2 -Wall -Wextra -Werror -arch arm64
-mmacosx-version-min=14.6`. This records reproducible inputs and flags; it does
not promise byte-identical code signatures.

## Pro app embedding and Release validation

The existing Pro-only Xcode phase runs `embed-in-app.sh`, rebuilding the helper
under `DERIVED_FILE_DIR/WPEShaderCompiler`. Pass `WPE_SHADER_TOOLCHAIN_ROOT` as
an Xcode build setting so the phase receives it. Release fails for missing or
changed inputs and requires hardened runtime. Debug without the variable warns
and removes old embedded toolchain files; a configured but invalid staging root
fails rather than silently using old outputs.

The phase copies the helper into `Contents/MacOS`, the two libraries into
`Contents/Frameworks`, and all four notices unchanged into
`Contents/Resources/WPEShaderCompilerNotices`. It removes the pinned DXC build's
external rpaths, leaving `@loader_path` for MSC beside it. Every invocation
re-copies/re-signs all three files using Xcode's expanded signing identity and
runtime option; helper entitlements remain exactly sandbox + inherit. No mtime
shortcut can retain a prior signature or helper. The outer app is sealed by
Xcode after this phase. Lite has no phase and carries none of this toolchain.

Release runtime lookup is bundle-only. Debug can explicitly supply all three
`WPE_SHADERC`, `WPE_DXCOMPILER`, `WPE_METALIRCONVERTER` environment paths after
bundle lookup; it has no personal-path defaults. The staging variable is used
only at build time and is not consulted by the running Release app.

For local Release acceptance, retain strict nested signature/effective-entitlement,
architecture, dependency and output-hash checks on the actual produced bundle.
Then use the normal `Scene pipeline` / `Render with New Pipeline` UI and a cold
shader cache. Existing runtime logs record toolchain origin/identity, actual app
and child PIDs, each stage's exit and read-back output digests. `Copy All Scenes`
exports the existing parity snapshot and actual session presentation status.
Require the new pipeline's real present and zero unexplained shader/GPU errors;
repeat for GS/stage-in and warm-cache reload, and check actual Lite absence.
An archive containing files, a Debug test or a direct Terminal helper run is
separate evidence and cannot substitute for sandboxed Release product execution.

## Direct helper diagnostic

This example tests only the helper, not the app's sandboxed product entry. Set
`HLSL_INPUT` to an actual source file and create the output directory first:

```sh
build/wpe-shaderc/wpe-shaderc \
  --stage vertex --entry main \
  --input "$HLSL_INPUT" \
  --output-metallib build/wpe-shaderc/example.metallib \
  --output-reflection build/wpe-shaderc/example.json \
  --dxcompiler "$WPE_SHADER_TOOLCHAIN_ROOT/lib/libdxcompiler.dylib" \
  --metalirconverter "$WPE_SHADER_TOOLCHAIN_ROOT/lib/libmetalirconverter.dylib" \
  --bounds-check --min-macos 14.6.0
```

The entry defaults to `main`, the MSC minimum deployment target to `14.6.0`, and bounds checking is
enabled only with `--bounds-check`. Output parent directories must already exist.
DXC uses `vs_6_0`, `ps_6_0`, or `gs_6_0` with `-HV 2016 -O3 -Ges`.
Reflection follows the supplied schema 1: DXC provides cbuffer layouts and
resources; MSC provides argument offsets, input/output signatures, and its raw
JSON object. DXC diagnostics go to stderr; compilation and output I/O failures
return nonzero.

Geometry programs run as MSC geometry emulation (a mesh pipeline). The geometry
stage is always compiled with emulation enabled. Its vertex stage is compiled
with `--output-stage-in path`: emulation plus a separate stage-in function, which
MSC synthesizes from one interleaved slot-0 layout packed tightly in VS input
signature order, written as a second metallib. The fragment stage compiles as
usual. The VS reflection's `state.vertex_output_size_in_bytes` and the GS's
`state.max_input_primitives_per_mesh_threadgroup` configure the pipeline and
draw (`IRRuntimeGeometryPipelineConfig`). Without `--output-stage-in`, vertex
and fragment output is unchanged.

The legacy `verify_captures.py` diagnostic still depends on its external capture
and local-installation paths; it is not the staged build or Release acceptance
gate. That standard-library-only verifier uses the supplied 145 captures, enables
bounds checking, and removes temporary artifacts from the ignored build
directory after verification. It compares same-name cbuffers and variables in
the matching FXC stage. `X/Y` counts matching versus compared shared variables;
optimized-away declarations are not counted. The captured geometry RDEF uses
`18259` (`0x4753`, ASCII `GS`), although the schema notes specify `65533`.
The paired DXBC SHEX stage tokens confirm geometry type `2` for all seven;
the verifier accepts both tags. Timing and metallib size statistics go to
stderr; the required summary and any layout mismatches go to stdout. The median
measures the complete short-lived helper process, including library loading,
DXC, MSC, and output I/O, once per capture.

## Library license notices

The Pro bundle includes the pinned DXC `LICENSE.TXT` (University of Illinois/NCSA
and third-party notices), DirectX-Headers MIT `LICENSE`, MSC Apache-2.0
`LICENSE.txt` and the complete original MSC `Acknowledgements.rtf`. The latter
contains DXVK, DirectX-Specs, DirectX Headers, DirectXMath, AMD, xxHash and DXC/LLVM
sections; do not replace it with a short attribution summary. Converter/runtime
notice pairs in the observed SDK are byte-identical, so one copy of each suffices
for this recorded file inventory.

The exact compiler-binary redistribution terms and MSC installer license remain
**unconfirmed**. Including installed header licenses and acknowledgements does
not settle those terms. Local implementation/build/runtime acceptance and final
distribution-license review remain separate; this change makes no claim that
distribution permission is closed.
