# WPE shader compiler helper

`wpe-shaderc` is a standalone C++17, arm64 helper targeting macOS 14.6.
It loads DXC and Metal Shader Converter (MSC) with `dlopen`; neither library
is linked into the helper or the app. Build against the already installed
headers using `clang++` (the header paths are in `build.sh`):

```sh
bash WPEShaderCompiler/build.sh /tmp/wpe-shaderc-build
/tmp/wpe-shaderc-build/wpe-shaderc \
  --stage vertex --entry main \
  --input /Users/example/Developer/wpe-fixtures/hlsl-capture-2026-10-12/hlsl/src_0x1.hlsl \
  --output-metallib /tmp/example.metallib \
  --output-reflection /tmp/example.json \
  --dxcompiler /Users/example/Developer/DirectXShaderCompiler/build-14.6/lib/libdxcompiler.dylib \
  --metalirconverter /usr/local/lib/libmetalirconverter.dylib \
  --bounds-check --min-macos 14.6.0
python3 WPEShaderCompiler/verify_captures.py --compiler /tmp/wpe-shaderc-build/wpe-shaderc
```

Omitting the build directory uses `WPEShaderCompiler/build/`. The entry defaults
to `main`, the MSC minimum deployment target to `14.6.0`, and bounds checking is
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

The standard-library-only verifier uses the supplied 145 captures, enables
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

Redistribution terms for both compiler libraries are **not yet confirmed**;
this task does not package or redistribute them. Before shipping, confirm the
terms for the exact binaries and bundled third-party components and preserve
all applicable licenses, copyright notices, disclaimers and attribution.
DXC's installed `LICENSE.TXT` contains the University of Illinois/NCSA license
and third-party notices; reproduce required notices with any binary distribution.
MSC's installed headers and `LICENSE.txt` carry Apache-2.0; preserve that license
and applicable notices, including any supplied NOTICE file. The header license
alone does not establish the redistribution terms for the MSC binary or SDK.
