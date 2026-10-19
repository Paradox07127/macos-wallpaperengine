# WPE shader compiler helper

`wpe-shaderc` is a C++17, arm64 helper targeting macOS 14.6. It loads DXC and
Metal Shader Converter (MSC) with `dlopen`; neither library is linked into the
helper or the app. Its runtime produces metallib bytes directly through MSC;
it does not require Xcode, `dxc`, `metal-shaderconverter` or a Metal compiler CLI
on the user's machine.

## Pinned build inputs

Set `WPE_SHADER_TOOLCHAIN_ROOT` explicitly to an input directory. There is no
installation-path or developer-home default. `toolchain-inputs.sha256` pins
32 files relative to that directory: 24 headers, two libraries and six complete
notices. `build.sh` verifies every pin before compiling the current `main.cpp`
with the selected Xcode SDK's `clang++`; it does not copy a prebuilt helper.

```text
include/dxc/                    dxcapi.h, WinAdapter.h
include/directx/                d3d12shader.h, d3dcommon.h
include/wsl/stubs/              rpc.h, rpcndr.h, OAIdl.h, OCIdl.h
include/metal_irconverter/      metal_irconverter.h and its 15 ir_*.h includes
lib/                           libdxcompiler.dylib, libmetalirconverter.dylib
licenses/                      DXC-LICENSE.TXT, DXC-ThirdPartyNotices.txt,
                               DirectX-Headers-LICENSE, MSC-LICENSE.txt,
                               MSC-Acknowledgements.rtf, MSC-EULA.rtf
```

The pinned DXC inputs come from v1.9.2609, source commit
`01b62ad47db7dee3dd33f90e7339cf9e860b3f93`, with DirectX-Headers submodule
`980971e835876dc0cde415e8f9bc646e64667bf7`. `build-dxcompiler.sh <work-dir>
<toolchain-root>` reproduces the library from a fresh depth-1 clone: arm64,
minimum macOS 14.6, MinSizeRel, assertions/tests disabled, SPIR-V codegen and
the MetalIRConverter link disabled. Non-Windows hosts force SPIR-V on, so the
script edits that `CMakeLists.txt` line and marks it assume-unchanged; the
library must report `dxc(private) 1.9.0.1 (01b62ad4)` with no `-dirty`, because
MSC's ShaderID depends on it. The staged copy is `strip -x`ed; the unstripped
library stays in the work directory for symbolication.

The pinned MSC inputs come from the matching Metal
Shader Converter 4.0 beta 3 package, whose version header declares 4.0.3. All
converter headers, the universal library and MSC notices were staged together
from that package; DXC inputs remain byte-identical. Relative to the earlier
4.0.1 SDK, only `ir_version.h`, `metal_irconverter.h` and
`libmetalirconverter.dylib` have changed hashes. The new library SHA256 is
`cc487a757f431c83483346c06a3ae8558910ecc510ce59b1e4f905d5d6d72bd4`.
Both arm64 and x86_64 slices are preserved, with minimum macOS 13.0. The app and
helper deployment requirement remains macOS 14.6. This input update is an
independent upgrade evaluation, not evidence of visual parity or performance
improvement.

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
`Contents/Frameworks`, and all six notices unchanged into
`Contents/Resources/WPEShaderCompilerNotices`. Before the toolchain check, so
Debug builds get them too, it copies the vendored FreeType, HarfBuzz and msdfgen
notices plus `ThirdPartyNotices/README.txt` into
`Contents/Resources/ThirdPartyNotices`. Every invocation re-copies/re-signs all three files using Xcode's expanded signing identity and
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
DXC uses `vs_6_0`, `ps_6_0`, or `gs_6_0` with `-HV 2016 -O3 -Ges -flegacy-macro-expansion`.
Reflection follows the supplied schema 1: DXC provides cbuffer layouts and
resources; MSC provides argument offsets, input/output signatures, and its raw
JSON object. A vertex stage with inputs DXC reports unread also gets
`unusedVertexInputs`, the semantics the app prunes before compiling once more.
DXC diagnostics go to stderr; compilation and output I/O failures
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

## Library license notices

The Pro bundle includes the pinned DXC `LICENSE.TXT` (University of Illinois/NCSA)
and its `ThirdPartyNotices.txt`, DirectX-Headers MIT `LICENSE`, MSC Apache-2.0
`LICENSE.txt` and the complete original MSC
`Acknowledgements.rtf`. `ThirdPartyNotices/manifest.tsv` lists every bundled
library's notices and `scripts/check_third_party_notices.py` gates them. The MSC acknowledgements file
contains DXVK, DirectX-Specs, DirectX Headers, DirectXMath, AMD, xxHash and DXC/LLVM
sections; do not replace it with a short attribution summary. Converter/runtime
notice pairs in the observed SDK are byte-identical, so one copy of each suffices
for this recorded file inventory.

`embed-in-app.sh` preserves the original universal `libmetalirconverter.dylib` input
without architecture thinning, symbol stripping or install-name changes. It only
re-signs the copied library using the app's identity for Hardened Runtime library
validation. The helper is arm64 and loads the arm64 slice; retaining the unused
x86_64 slice does not change the Pro host architecture. DXC's existing build and
thinning policy is separate.

The complete original `MSC-EULA.rtf` is also pinned and shipped. It is Apple's
Software License Agreement for Metal Shader Converter, EA1844, dated 5/31/2023.
Section 2B explicitly permits distribution of its defined Dynamic Libraries for
the sole purpose of shader conversion. Section 2E separately restricts modification,
subject to its stated exceptions; do not infer a compiler-binary modification
grant from an installed header's generic Apache-2.0 notice.

EULA provenance: the English `Resources/English.lproj/License.rtf` in the official
Apple download at
`https://download.developer.apple.com/Developer_Tools/Metal_Shader_Converter_3.1_beta_1/Metal_Shader_Converter_4.0_beta_3.pkg`.
The package SHA256 is
`bf85647b33ca54a0a8ba5b44e650db72aefbf097c98f291fa1dff8a4bfb0017e`;
the unchanged license SHA256 is
`20108dfe30663a2c6c717d9c5ca92486d9a4682c85c8ab344b20470feac8d0c3`.
The package's Distribution file points to that license and records package version
`1.0.1.1791495856`. The authenticated official download was expanded only; it was
not installed or executed. `pkgutil --check-signature` reported an invalid package
signature, so authenticated download provenance and that signature limitation are
recorded separately rather than claiming package-signature verification.

This beta 3 package supplies the matching library/header inputs pinned in this
input set. It is not the original installer for the earlier installed
4.0.1 SDK; that archive remains unavailable. Package signature verification is
still limited as recorded above. The EULA is an explicit dynamic-library
redistribution grant from the obtained Apple package, not a comprehensive
legal/compliance audit. Keep the generic open-source licenses and
acknowledgements alongside the Apple agreement; local compiler, sandboxed
runtime, actual GPU output and final artifact acceptance remain separate gates.

The runtime compiler identity hashes the helper and both library files. The
changed MSC library therefore gives newly compiled shaders a different cache
key even if the helper executable bytes are unchanged. Existing precompiled
scene capsules retain their recorded compiler identity; updating the app's
compiler does not retroactively relabel those metallibs. Upgrade validation
must use cold compile requests and explicitly reprepare any capsules it intends
to validate against 4.0.3.
