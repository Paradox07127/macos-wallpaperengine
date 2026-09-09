#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Exhaustive adapters retain the original payload for diagnostics. Presentation
/// never infers a decoder or parser failure from a generic NSError string.
enum SceneFailureCause {
    static func make(_ error: Error) -> WallpaperFailureCause {
        switch error {
        case let error as SceneRenderingError:
            switch error {
            case .cacheRootMissing: return cause("scene.cache_missing", error)
            case .parseFailed: return cause("scene.parse", error, retry: false)
            case let .resourceFailed(diagnostic): return make(diagnostic)
            case .metalRendererUnsupported: return cause("scene.metal_unsupported", error, retry: false)
            }
        case let error as WPESceneDocumentError:
            let code = switch error {
            case .invalidUTF8: "invalid_utf8"
            case .rootNotObject: "root_not_object"
            case .missingCamera: "missing_camera"
            case .missingGeneral: "missing_general"
            case .malformedField: "malformed_field"
            }
            return cause("scene.document.\(code)", error, retry: false)
        case let error as WPETexDecodeError: return texture(error)
        case let error as WPEMetalTextureLoaderError:
            switch error {
            case .unsupportedFormat: return cause("texture.metal_format", error, retry: false)
            case .unsupportedCompressedFormat: return cause("texture.metal_compression", error, retry: false)
            case .malformedPayload: return cause("texture.payload", error, retry: false)
            case .textureAllocationFailed: return cause("texture.allocation", error)
            }
        case let error as WPERenderGraphError:
            switch error {
            case .fileMissing: return cause("graph.file_missing", error)
            case .invalidJSON: return cause("graph.json", error, retry: false)
            case .malformedMaterial: return cause("graph.material", error, retry: false)
            case .malformedEffect: return cause("graph.effect", error, retry: false)
            case .materialUnresolved: return cause("graph.reference", error, retry: false)
            }
        case let error as WPESceneAssetProviderError:
            let code: String
            let reason: String
            switch error {
            case let .invalidRelativePath(path):
                code = "scene.unsafe_path"
                reason = String(localized: "The scene resource path is not safe to open: \(path)", bundle: .appLanguage)
            case let .fileMissing(path):
                code = "scene.file_missing"
                reason = String(localized: "A required scene file is missing: \(path)", bundle: .appLanguage)
            case let .unreadable(path):
                code = "scene.unreadable"
                reason = String(localized: "The scene resource could not be read: \(path)", bundle: .appLanguage)
            case let .stagingUnavailable(path):
                code = "scene.staging"
                reason = String(localized: "A temporary scene resource could not be prepared: \(path)", bundle: .appLanguage)
            }
            return WallpaperFailureCause(code: code, reason: reason, canRetry: code != "scene.unsafe_path", details: String(reflecting: error))
        case let error as WPEPackageError:
            let reason = switch error {
            case .truncatedHeader:
                String(localized: "The scene package header is truncated.", bundle: .appLanguage)
            case let .invalidMagic(magic):
                String(localized: "The scene package format is not recognized: \(magic)", bundle: .appLanguage)
            case let .invalidEntryName(index):
                String(localized: "The scene package has an invalid entry name at index \(index).", bundle: .appLanguage)
            case let .entryOutOfBounds(name):
                String(localized: "A scene package entry extends beyond the available data: \(name)", bundle: .appLanguage)
            case let .pathTraversal(name):
                String(localized: "A scene package entry refers outside the project: \(name)", bundle: .appLanguage)
            case let .duplicateEntry(name):
                String(localized: "The scene package contains a duplicate entry: \(name)", bundle: .appLanguage)
            case let .resourceLimitExceeded(limit):
                String(localized: "The scene package exceeds a supported resource limit: \(limit.rawValue)", bundle: .appLanguage)
            }
            return WallpaperFailureCause(code: error.stableReasonCode, reason: reason, canRetry: false, details: String(reflecting: error))
        case let error as WPEMdlParserError:
            return model(error)
        default:
            let nsError = error as NSError
            return WallpaperFailureCause(code: "\(nsError.domain).\(nsError.code)", reason: nsError.localizedDescription, details: String(reflecting: error))
        }
    }

    static func make(_ diagnostic: SceneLoadDiagnostic) -> WallpaperFailureCause {
        let code: String
        let retry: Bool
        switch diagnostic {
        case let .texture(_, error):
            let nested = texture(error)
            return WallpaperFailureCause(code: nested.code, reason: diagnostic.errorDescription, canRetry: nested.canRetry, details: String(reflecting: diagnostic))
        case .legacyUnsupportedTexture: (code, retry) = ("scene.legacy_texture", false)
        case .fileMissing: (code, retry) = ("scene.file_missing", true)
        case .crossPackageReference: (code, retry) = ("scene.cross_package", false)
        case .materialUnresolved: (code, retry) = ("scene.material", false)
        case .other: (code, retry) = ("scene.other", true)
        }
        return WallpaperFailureCause(code: code, reason: diagnostic.errorDescription, canRetry: retry, details: String(reflecting: diagnostic))
    }

    private static func texture(_ error: WPETexDecodeError) -> WallpaperFailureCause {
        let code: String
        let retry: Bool
        switch error {
        case .unsupportedContainer: (code, retry) = ("container", false)
        case .unsupportedBlock: (code, retry) = ("block", false)
        case .missingInfoBlock: (code, retry) = ("missing_info", false)
        case .missingBitmapBlock: (code, retry) = ("missing_bitmap", false)
        case .unsupportedFormat: (code, retry) = ("format", false)
        case .unsupportedAnimation: (code, retry) = ("animation", false)
        case .invalidDimensions: (code, retry) = ("dimensions", false)
        case .truncatedBlock: (code, retry) = ("truncated", false)
        case .mipmapOutOfBounds: (code, retry) = ("mipmap_bounds", false)
        case .decompressionFailed: (code, retry) = ("decompression", false)
        case .decodeFailed: (code, retry) = ("decode", true)
        case .metalUnavailable: (code, retry) = ("metal_unavailable", false)
        }
        return cause("texture.\(code)", error, retry: retry)
    }

    private static func model(_ error: WPEMdlParserError) -> WallpaperFailureCause {
        let code = switch error {
        case .invalidHeader: "header"
        case .implausibleCount: "count"
        case .truncated: "truncated"
        case .unterminatedString: "unterminated_string"
        case .invalidString: "string"
        case .unsupportedSectionMarker: "section"
        case .invalidPartTable: "parts"
        case .invalidVertexBuffer: "vertices"
        case .invalidIndexBuffer: "indices"
        case .invalidSkeletonMatrix: "skeleton"
        case .invalidElementMatrixPayload: "matrix"
        case .invalidAttachmentHeader: "attachment"
        case .invalidAnimationHeader: "animation_header"
        case .invalidAnimationTail: "animation_tail"
        case .invalidAnimationChannelByteCount: "animation_bytes"
        case .invalidAnimationChannelDelimiter: "animation_delimiter"
        }
        return WallpaperFailureCause(code: "model.\(code)", reason: String(localized: "The scene's model data could not be read.", bundle: .appLanguage), canRetry: false, details: String(reflecting: error))
    }

    private static func cause(_ code: String, _ error: Error, retry: Bool = true) -> WallpaperFailureCause {
        WallpaperFailureCause(code: code, reason: error.localizedDescription, canRetry: retry, details: String(reflecting: error))
    }
}
#endif
