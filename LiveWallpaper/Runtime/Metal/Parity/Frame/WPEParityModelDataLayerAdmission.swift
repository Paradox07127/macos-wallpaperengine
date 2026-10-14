#if !LITE_BUILD
import CoreFoundation
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// Admission into the existing canonical State and frame planner. This type owns no layers or model table.
enum WPEParityModelDataLayerAdmission {
    static func provider(
        plan: WPEParityFramePlan, device: MTLDevice,
        admitShape: @escaping (WPEParitySceneModelData.Shape, WPEParityModelDataMutation)
            throws -> (any WPEParityModelDataPreparedShape)?
    ) -> WPEParityScriptModelDataProvider {
        WPEParityScriptModelDataProvider(
            maximumArrayEntries: Int(UInt32.max), maximumBufferBytes: Int.max,
            maximumSingleBufferBytes: device.maxBufferLength,
            resolveMaterial: { value, context in
                guard let context, context.assetsPrepared, value.isString, let path = value.toString(),
                      context.registeredAssets.contains(where: {
                          $0.flag && $0.path.utf8.elementsEqual(path.utf8)
                      }) else {
                    throw WPEParityModelDataFailure.safety("material requires its prepared binding registration")
                }
                // The complete native path composition contract remains separate. This finite literal subset
                // has an actual binding registration, material reader and shader-load consumer.
                let bytes = Data(path.utf8)
                guard bytes.count <= 255, !bytes.contains(0), !path.contains("\\"), !path.contains("//") else {
                    throw WPEParityModelDataFailure.safety("registered material filename requires unqualified path conversion")
                }
                guard plan.scene.modelDataMesh(materialPath: path) != nil else {
                    throw WPEParityModelDataFailure.native(1)
                }
                return bytes
            },
            admitShape: admitShape
        )
    }

    /// Explicit numeric identity and literal TRS form the bounded warm model transaction. Other classes,
    /// parents/effects/placement and new scripted dependencies require their actual resource adoption first.
    static func create(_ json: String, state: inout WPEParitySceneState) -> WPEParityScriptEngine.CreatedLayer? {
        do {
            guard let config = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  Set(config.keys).isSubset(of: ["id", "name", "model", "origin", "scale", "angles", "visible"]),
                  config.values.allSatisfy(isLiteral),
                  let number = config["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let id = UInt32(exactly: number.doubleValue), id > 0 else {
                throw WPEParityModelDataFailure.safety("dynamic model layer configuration is outside the admitted literal subset")
            }
            for field in ["origin", "angles"] {
                if let value = config[field], WPEValueParser.vector3(value) == nil {
                    throw WPEParityModelDataFailure.safety("dynamic model layer requires a literal \(field) vector")
                }
            }
            if let scale = config["scale"], WPEValueParser.vector3(scale) == nil, WPEValueParser.double(scale) == nil {
                throw WPEParityModelDataFailure.safety("dynamic model layer requires a literal scale")
            }
            guard let descriptor = WPESceneDocumentParser.parseModelDataLayerConfiguration(config),
                  descriptor.id == String(id), let model = state.modelData(descriptor.modelDataToken),
                  model.shapes.allSatisfy({ $0.prepared is WPEParityModelDataMetalShape }) else {
                throw WPEParityModelDataFailure.safety("numeric model has no prepared canonical shape consumer")
            }
            try state.appendModelDataLayer(descriptor)
            return .init(id: descriptor.id, configJSON: json)
        } catch {
            Logger.warning("ModelData layer admission: \(error)", category: .wpeRender)
            return nil
        }
    }

    private static func isLiteral(_ value: Any) -> Bool {
        if value is [String: Any] {
            return false
        }
        if let array = value as? [Any] {
            return array.allSatisfy(isLiteral)
        }
        return true
    }
}
#endif
