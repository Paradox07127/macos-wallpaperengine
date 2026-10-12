#include <dxcapi.h>
#define interface struct
#include <d3d12shader.h>
#undef interface
#include <metal_irconverter/metal_irconverter.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void check(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        std::ostringstream message;
        message << operation << " failed (HRESULT 0x" << std::hex << uint32_t(result) << ')';
        throw std::runtime_error(message.str());
    }
}

template <typename T> struct ComPtr {
    T* value = nullptr;
    ~ComPtr() { if (value) value->Release(); }
    ComPtr() = default;
    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;
    T* operator->() const { return value; }
    T** address() { return &value; }
    void** out() { return reinterpret_cast<void**>(&value); }
};

class Library {
public:
    explicit Library(const std::string& path) : handle(dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL)) {
        if (!handle) throw std::runtime_error("dlopen " + path + ": " + dlerror());
    }
    ~Library() { dlclose(handle); }
    Library(const Library&) = delete;
    Library& operator=(const Library&) = delete;

    template <typename T> T symbol(const char* name) const {
        dlerror();
        auto result = reinterpret_cast<T>(dlsym(handle, name));
        const char* error = dlerror();
        if (error) throw std::runtime_error(std::string("dlsym ") + name + ": " + error);
        return result;
    }
private:
    void* handle;
};

struct Options {
    std::string stage, input, metallib, reflection, dxcompiler, metalirconverter;
    std::string entry = "main", minMacOS = "14.6.0";
    bool boundsCheck = false;
};

const char* usage =
    "wpe-shaderc --stage vertex|fragment|geometry --input file.hlsl\n"
    "  --output-metallib path --output-reflection path --dxcompiler path\n"
    "  --metalirconverter path [--entry main] [--bounds-check] [--min-macos 14.6.0]\n";

Options parseOptions(int argc, char** argv) {
    Options options;
    std::map<std::string, std::string*> fields = {
        {"--stage", &options.stage}, {"--input", &options.input},
        {"--output-metallib", &options.metallib}, {"--output-reflection", &options.reflection},
        {"--dxcompiler", &options.dxcompiler}, {"--metalirconverter", &options.metalirconverter},
        {"--entry", &options.entry}, {"--min-macos", &options.minMacOS}
    };
    for (int i = 1; i < argc; ++i) {
        std::string argument = argv[i];
        if (argument == "--bounds-check") { options.boundsCheck = true; continue; }
        auto field = fields.find(argument);
        require(field != fields.end(), "Unknown argument: " + argument);
        require(i + 1 < argc, "Missing value for " + argument);
        *field->second = argv[++i];
    }
    for (const auto& field : fields) require(!field.second->empty(), "Missing " + field.first);
    require(options.stage == "vertex" || options.stage == "fragment" || options.stage == "geometry",
            "Invalid --stage: " + options.stage);
    require(std::regex_match(options.minMacOS, std::regex("[0-9]+\\.[0-9]+(\\.[0-9]+)?")),
            "Invalid --min-macos: " + options.minMacOS);
    auto input = std::filesystem::absolute(options.input).lexically_normal();
    auto metallib = std::filesystem::absolute(options.metallib).lexically_normal();
    auto reflection = std::filesystem::absolute(options.reflection).lexically_normal();
    require(input != metallib && input != reflection && metallib != reflection,
            "Input and output paths must be distinct");
    return options;
}

std::string quote(std::string_view value) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : value) {
        switch (c) {
            case '"': out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << unsigned(c);
                else out << c;
        }
    }
    out << '"';
    return out.str();
}

std::string array(const std::vector<std::string>& items) {
    std::string result = "[";
    for (const auto& item : items) {
        if (result.size() > 1) result += ',';
        result += item;
    }
    return result + ']';
}

void writeFile(const std::string& path, const void* bytes, size_t size) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    require(bool(file), "Cannot open output: " + path);
    file.write(static_cast<const char*>(bytes), size);
    file.close();
    require(bool(file), "Cannot write output: " + path);
}

void writeFile(const std::string& path, const std::string& text) {
    writeFile(path, text.data(), text.size());
}

const char* baseType(D3D_SHADER_VARIABLE_TYPE type) {
    switch (type) {
        case D3D_SVT_FLOAT: return "float";
        case D3D_SVT_INT: return "int";
        case D3D_SVT_UINT: return "uint";
        case D3D_SVT_BOOL: return "bool";
        default: throw std::runtime_error("Unsupported cbuffer base type: " + std::to_string(type));
    }
}

const char* variableClass(D3D_SHADER_VARIABLE_CLASS type) {
    switch (type) {
        case D3D_SVC_SCALAR: return "scalar";
        case D3D_SVC_VECTOR: return "vector";
        case D3D_SVC_MATRIX_ROWS: return "matrix_rows";
        case D3D_SVC_MATRIX_COLUMNS: return "matrix_columns";
        case D3D_SVC_STRUCT: return "struct";
        default: throw std::runtime_error("Unsupported cbuffer variable class");
    }
}

const char* dimension(D3D_SRV_DIMENSION value) {
    switch (value) {
        case D3D_SRV_DIMENSION_UNKNOWN: case D3D_SRV_DIMENSION_BUFFER: return "none";
        case D3D_SRV_DIMENSION_TEXTURE2D: return "2d";
        case D3D_SRV_DIMENSION_TEXTURE2DMS: return "2dms";
        case D3D_SRV_DIMENSION_TEXTURE3D: return "3d";
        case D3D_SRV_DIMENSION_TEXTURECUBE: return "cube";
        case D3D_SRV_DIMENSION_TEXTURE2DARRAY: return "2darray";
        default: throw std::runtime_error("Unsupported resource dimension: " + std::to_string(value));
    }
}

struct Reflection {
    std::string cbuffers = "[]", resources = "[]", arguments = "[]";
    std::string inputs = "[]", outputs = "[]", msc = "{}";

    std::string json(const Options& options) const {
        return "{\"schema\":1,\"stage\":" + quote(options.stage) + ",\"entry\":" + quote(options.entry)
            + ",\"cbuffers\":" + cbuffers + ",\"resources\":" + resources
            + ",\"topLevelArgumentBuffer\":" + arguments + ",\"vertexInputs\":" + inputs
            + ",\"stageOutputs\":" + outputs + ",\"mscReflection\":" + msc + "}\n";
    }
};

void reflectDXC(ID3D12ShaderReflection* shader, Reflection& reflection) {
    D3D12_SHADER_DESC desc{};
    check(shader->GetDesc(&desc), "Shader GetDesc");
    std::vector<std::string> cbuffers, resources;
    for (UINT i = 0; i < desc.ConstantBuffers; ++i) {
        auto* buffer = shader->GetConstantBufferByIndex(i);
        D3D12_SHADER_BUFFER_DESC bufferDesc{};
        check(buffer->GetDesc(&bufferDesc), "Cbuffer GetDesc");
        D3D12_SHADER_INPUT_BIND_DESC binding{};
        check(shader->GetResourceBindingDescByName(bufferDesc.Name, &binding), "Cbuffer binding");
        std::vector<std::string> variables;
        for (UINT j = 0; j < bufferDesc.Variables; ++j) {
            auto* variable = buffer->GetVariableByIndex(j);
            D3D12_SHADER_VARIABLE_DESC v{};
            D3D12_SHADER_TYPE_DESC t{};
            check(variable->GetDesc(&v), "Variable GetDesc");
            check(variable->GetType()->GetDesc(&t), "Variable type GetDesc");
            variables.push_back("{\"name\":" + quote(v.Name) + ",\"offset\":" + std::to_string(v.StartOffset)
                + ",\"size\":" + std::to_string(v.Size) + ",\"baseType\":" + quote(baseType(t.Type))
                + ",\"class\":" + quote(variableClass(t.Class)) + ",\"rows\":" + std::to_string(t.Rows)
                + ",\"columns\":" + std::to_string(t.Columns) + ",\"elements\":" + std::to_string(t.Elements)
                + ",\"used\":" + ((v.uFlags & D3D_SVF_USED) ? "true" : "false") + '}');
        }
        cbuffers.push_back("{\"name\":" + quote(bufferDesc.Name) + ",\"register\":" + std::to_string(binding.BindPoint)
            + ",\"space\":" + std::to_string(binding.Space) + ",\"size\":" + std::to_string(bufferDesc.Size)
            + ",\"variables\":" + array(variables) + '}');
    }
    for (UINT i = 0; i < desc.BoundResources; ++i) {
        D3D12_SHADER_INPUT_BIND_DESC b{};
        check(shader->GetResourceBindingDesc(i, &b), "Resource binding");
        if (b.Type == D3D_SIT_CBUFFER) continue;
        const char* kind = nullptr;
        switch (b.Type) {
            case D3D_SIT_TEXTURE: kind = "texture"; break;
            case D3D_SIT_SAMPLER: kind = "sampler"; break;
            default: throw std::runtime_error("Unsupported resource kind: " + std::to_string(b.Type));
        }
        resources.push_back("{\"name\":" + quote(b.Name) + ",\"kind\":" + quote(kind)
            + ",\"register\":" + std::to_string(b.BindPoint) + ",\"space\":" + std::to_string(b.Space)
            + ",\"dimension\":" + quote(dimension(b.Dimension)) + ",\"count\":" + std::to_string(b.BindCount)
            + ((b.Type == D3D_SIT_SAMPLER && (b.uFlags & D3D_SIF_COMPARISON_SAMPLER)) ? ",\"comparison\":true" : "") + '}');
    }
    reflection.cbuffers = array(cbuffers);
    reflection.resources = array(resources);
}

// Extract complete JSON values without reserializing MSC's raw reflection.
class JSONView {
public:
    explicit JSONView(std::string_view text) : text(text) {}

    std::vector<std::string_view> values() const {
        size_t pos = 1;
        std::vector<std::string_view> result;
        skip(pos);
        while (pos < text.size() && text[pos] != ']') {
            result.push_back(value(pos));
            skip(pos);
            if (pos < text.size() && text[pos] == ',') ++pos;
            skip(pos);
        }
        return result;
    }

    std::string member(const std::string& name) const {
        size_t pos = 1;
        skip(pos);
        while (pos < text.size() && text[pos] != '}') {
            auto key = value(pos);
            skip(pos);
            require(pos < text.size() && text[pos++] == ':', "Invalid MSC JSON member");
            skip(pos);
            auto item = value(pos);
            if (key == quote(name)) return std::string(item);
            skip(pos);
            if (pos < text.size() && text[pos] == ',') ++pos;
            skip(pos);
        }
        return {};
    }
private:
    std::string_view text;
    void skip(size_t& pos) const {
        while (pos < text.size() && std::isspace(static_cast<unsigned char>(text[pos]))) ++pos;
    }
    std::string_view value(size_t& pos) const {
        skip(pos);
        size_t start = pos;
        require(pos < text.size(), "Truncated MSC JSON");
        if (text[pos] == '"') {
            ++pos;
            while (pos < text.size()) {
                if (text[pos++] == '"') return text.substr(start, pos - start);
                if (text[pos - 1] == '\\') ++pos;
            }
            throw std::runtime_error("Unterminated MSC JSON string");
        }
        if (text[pos] == '{' || text[pos] == '[') {
            char closing = text[pos++] == '{' ? '}' : ']';
            while (pos < text.size()) {
                skip(pos);
                if (pos < text.size() && text[pos] == closing) {
                    ++pos;
                    return text.substr(start, pos - start);
                }
                if (pos < text.size() && (text[pos] == ',' || text[pos] == ':')) ++pos;
                else value(pos);
            }
            throw std::runtime_error("Unterminated MSC JSON container");
        }
        while (pos < text.size() && text[pos] != ',' && text[pos] != '}' && text[pos] != ']'
               && !std::isspace(static_cast<unsigned char>(text[pos]))) ++pos;
        return text.substr(start, pos - start);
    }
};

std::string signature(const JSONView& raw, const std::string& key) {
    auto list = raw.member(key);
    if (list.empty()) return "[]";
    std::vector<std::string> result;
    for (auto item : JSONView(list).values()) {
        JSONView field(item);
        auto name = field.member("name"), index = field.member("index");
        auto type = field.member("elementType"), columns = field.member("columnCount");
        require(!name.empty() && !index.empty() && !type.empty() && !columns.empty(),
                "MSC signature metadata incomplete: " + key);
        result.push_back("{\"name\":" + name + ",\"index\":" + index
            + ",\"elementType\":" + type + ",\"columns\":" + columns + '}');
    }
    return array(result);
}

struct MSC : Library {
#define MSC_FUNCTION(name) decltype(&::name) name = symbol<decltype(&::name)>(#name)
    MSC_FUNCTION(IRCompilerCreate);
    MSC_FUNCTION(IRCompilerDestroy);
    MSC_FUNCTION(IRCompilerSetMinimumDeploymentTarget);
    MSC_FUNCTION(IRCompilerSetCompatibilityFlags);
    MSC_FUNCTION(IRCompilerSetEntryPointName);
    MSC_FUNCTION(IRCompilerEnableGeometryAndTessellationEmulation);
    MSC_FUNCTION(IRObjectCreateFromDXIL);
    MSC_FUNCTION(IRObjectDestroy);
    MSC_FUNCTION(IRCompilerAllocCompileAndLink);
    MSC_FUNCTION(IRErrorGetCode);
    MSC_FUNCTION(IRErrorDestroy);
    MSC_FUNCTION(IRObjectGetMetalLibBinary);
    MSC_FUNCTION(IRMetalLibBinaryCreate);
    MSC_FUNCTION(IRMetalLibBinaryDestroy);
    MSC_FUNCTION(IRMetalLibGetBytecodeSize);
    MSC_FUNCTION(IRMetalLibGetBytecode);
    MSC_FUNCTION(IRShaderReflectionCreate);
    MSC_FUNCTION(IRShaderReflectionDestroy);
    MSC_FUNCTION(IRObjectGetReflection);
    MSC_FUNCTION(IRShaderReflectionGetResourceCount);
    MSC_FUNCTION(IRShaderReflectionGetResourceLocations);
    MSC_FUNCTION(IRShaderReflectionCopyJSONString);
    MSC_FUNCTION(IRShaderReflectionReleaseString);
#undef MSC_FUNCTION
    using Library::Library;
};

std::vector<uint8_t> convert(MSC& msc, const Options& options, IDxcBlob* dxil, Reflection& reflection) {
    auto compiler = std::unique_ptr<IRCompiler, decltype(msc.IRCompilerDestroy)>(
        msc.IRCompilerCreate(), msc.IRCompilerDestroy);
    require(bool(compiler), "MSC could not create compiler");
    msc.IRCompilerSetMinimumDeploymentTarget(compiler.get(), IROperatingSystem_macOS, options.minMacOS.c_str());
    msc.IRCompilerSetCompatibilityFlags(compiler.get(), options.boundsCheck ? IRCompatibilityFlagBoundsCheck : IRCompatibilityFlagNone);
    msc.IRCompilerSetEntryPointName(compiler.get(), options.entry.c_str());
    bool geometry = options.stage == "geometry";
    if (geometry) msc.IRCompilerEnableGeometryAndTessellationEmulation(compiler.get(), true);
    auto input = std::unique_ptr<IRObject, decltype(msc.IRObjectDestroy)>(
        msc.IRObjectCreateFromDXIL(static_cast<const uint8_t*>(dxil->GetBufferPointer()),
                                 dxil->GetBufferSize(), IRBytecodeOwnershipNone), msc.IRObjectDestroy);
    require(bool(input), "MSC could not read DXIL");
    IRError* error = nullptr;
    auto object = std::unique_ptr<IRObject, decltype(msc.IRObjectDestroy)>(
        msc.IRCompilerAllocCompileAndLink(compiler.get(), nullptr, input.get(), &error), msc.IRObjectDestroy);
    auto ownedError = std::unique_ptr<IRError, decltype(msc.IRErrorDestroy)>(error, msc.IRErrorDestroy);
    if (!object) {
        std::string message = "MSC compile failed";
        if (error) {
            message += " (code " + std::to_string(msc.IRErrorGetCode(error)) + ')';
        }
        throw std::runtime_error(message);
    }
    IRShaderStage stage = geometry ? IRShaderStageGeometry :
        (options.stage == "vertex" ? IRShaderStageVertex : IRShaderStageFragment);
    auto info = std::unique_ptr<IRShaderReflection, decltype(msc.IRShaderReflectionDestroy)>(
        msc.IRShaderReflectionCreate(), msc.IRShaderReflectionDestroy);
    require(info && msc.IRObjectGetReflection(object.get(), stage, info.get()), "MSC reflection unavailable");
    auto raw = std::unique_ptr<const char, decltype(msc.IRShaderReflectionReleaseString)>(
        msc.IRShaderReflectionCopyJSONString(info.get()), msc.IRShaderReflectionReleaseString);
    require(bool(raw), "MSC JSON reflection unavailable");
    reflection.msc = raw.get();
    JSONView json(reflection.msc);
    reflection.inputs = signature(json, "vertex_inputs");
    reflection.outputs = signature(json, "vertex_outputs");
    std::vector<IRResourceLocation> locations(msc.IRShaderReflectionGetResourceCount(info.get()));
    if (!locations.empty()) msc.IRShaderReflectionGetResourceLocations(info.get(), locations.data());
    std::vector<std::string> arguments;
    for (const auto& location : locations) {
        const char* kind = nullptr;
        switch (location.resourceType) {
            case IRResourceTypeCBV: kind = "cbv"; break;
            case IRResourceTypeSRV: kind = "srv"; break;
            case IRResourceTypeUAV: kind = "uav"; break;
            case IRResourceTypeSampler: kind = "sampler"; break;
            default: throw std::runtime_error("Unsupported MSC argument type");
        }
        arguments.push_back("{\"kind\":" + quote(kind) + ",\"register\":" + std::to_string(location.slot)
            + ",\"space\":" + std::to_string(location.space) + ",\"offset\":" + std::to_string(location.topLevelOffset)
            + ",\"size\":" + std::to_string(location.sizeBytes) + '}');
    }
    reflection.arguments = array(arguments);
    auto binary = std::unique_ptr<IRMetalLibBinary, decltype(msc.IRMetalLibBinaryDestroy)>(
        msc.IRMetalLibBinaryCreate(), msc.IRMetalLibBinaryDestroy);
    require(binary && msc.IRObjectGetMetalLibBinary(object.get(), stage, binary.get()), "MSC metallib unavailable");
    std::vector<uint8_t> bytes(msc.IRMetalLibGetBytecodeSize(binary.get()));
    require(!bytes.empty() && msc.IRMetalLibGetBytecode(binary.get(), bytes.data()) == bytes.size(), "MSC empty or incomplete metallib");
    return bytes;
}

void compile(const Options& options) {
    Library dxc(options.dxcompiler);
    auto create = dxc.symbol<DxcCreateInstanceProc>("DxcCreateInstance");
    ComPtr<IDxcUtils> utils;
    ComPtr<IDxcCompiler3> compiler;
    check(create(CLSID_DxcUtils, __uuidof(IDxcUtils), utils.out()), "Create DXC utils");
    check(create(CLSID_DxcCompiler, __uuidof(IDxcCompiler3), compiler.out()), "Create DXC compiler");
    ComPtr<IDxcBlobEncoding> source;
    std::wstring input = std::filesystem::path(options.input).wstring();
    check(utils->LoadFile(input.c_str(), nullptr, source.address()), "Load HLSL");
    ComPtr<IDxcIncludeHandler> includes;
    check(utils->CreateDefaultIncludeHandler(includes.address()), "Create include handler");
    std::wstring profile = options.stage == "vertex" ? L"vs_6_0" : (options.stage == "fragment" ? L"ps_6_0" : L"gs_6_0");
    std::wstring entry(options.entry.begin(), options.entry.end());
    std::wstring includeDir = std::filesystem::absolute(options.input).parent_path().wstring();
    // WPE's FXC-era geometry HLSL requires the 2016 language rules.
    const wchar_t* args[] = {input.c_str(), L"-T", profile.c_str(), L"-E", entry.c_str(),
                            L"-HV", L"2016", L"-O3", L"-Ges", L"-I", includeDir.c_str()};
    DxcBuffer buffer{source->GetBufferPointer(), source->GetBufferSize(), DXC_CP_UTF8};
    ComPtr<IDxcResult> result;
    check(compiler->Compile(&buffer, args, sizeof(args) / sizeof(args[0]), includes.value,
                            __uuidof(IDxcResult), result.out()), "DXC Compile");
    ComPtr<IDxcBlobUtf8> errors;
    check(result->GetOutput(DXC_OUT_ERRORS, __uuidof(IDxcBlobUtf8), errors.out(), nullptr), "DXC errors");
    if (errors.value && errors->GetStringLength()) std::cerr.write(errors->GetStringPointer(), errors->GetStringLength());
    HRESULT status;
    check(result->GetStatus(&status), "DXC status");
    check(status, "HLSL compilation");
    ComPtr<IDxcBlob> dxil, reflectionBlob;
    check(result->GetOutput(DXC_OUT_OBJECT, __uuidof(IDxcBlob), dxil.out(), nullptr), "DXC DXIL output");
    check(result->GetOutput(DXC_OUT_REFLECTION, __uuidof(IDxcBlob), reflectionBlob.out(), nullptr), "DXC reflection output");
    require(dxil.value && reflectionBlob.value, "DXC output missing");
    DxcBuffer reflectionBuffer{reflectionBlob->GetBufferPointer(), reflectionBlob->GetBufferSize(), 0};
    ComPtr<ID3D12ShaderReflection> shader;
    check(utils->CreateReflection(&reflectionBuffer, __uuidof(ID3D12ShaderReflection), shader.out()), "CreateReflection");
    Reflection reflection;
    reflectDXC(shader.value, reflection);
    if (options.stage == "geometry") writeFile(options.reflection, reflection.json(options));
    MSC msc(options.metalirconverter);
    std::vector<uint8_t> metallib;
    try {
        metallib = convert(msc, options, dxil.value, reflection);
    } catch (const std::runtime_error& error) {
        if (options.stage != "geometry") throw;
        std::filesystem::remove(options.metallib);
        std::cerr << error.what() << "; geometry metallib skipped; DXC reflection retained.\n";
    }
    if (!metallib.empty()) writeFile(options.metallib, metallib.data(), metallib.size());
    writeFile(options.reflection, reflection.json(options));
    if (options.stage == "geometry") {
        std::cerr << "MSC geometry execution requires IRRuntimeNewGeometryEmulationPipeline with companion "
                     "vertex, fragment and stage-in libraries, pipeline reflection and a mesh pipeline descriptor "
                     "(MSC UserManual: Emulating geometry and tessellation pipelines).\n";
    }
}

} // namespace

int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--help") { std::cout << usage; return 0; }
    try {
        compile(parseOptions(argc, argv));
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "wpe-shaderc: " << error.what() << '\n';
        return 1;
    }
}
