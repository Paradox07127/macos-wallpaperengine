import Foundation
import JavaScriptCore

/// Required product resource admission. No default filename identity, material success or buffer budget is inferred.
public struct WPEParityScriptModelDataProvider {
    public var maximumArrayEntries: Int
    public var maximumBufferBytes: Int
    public var resolveMaterial: (JSValue, String) throws -> Data
    public var admitShape: (WPEParitySceneModelData.Shape, WPEParityModelDataMutation) throws -> (any WPEParityModelDataPreparedShape)?

    public init(maximumArrayEntries: Int, maximumBufferBytes: Int,
                resolveMaterial: @escaping (JSValue, String) throws -> Data,
                admitShape: @escaping (WPEParitySceneModelData.Shape, WPEParityModelDataMutation) throws -> (any WPEParityModelDataPreparedShape)?) {
        self.maximumArrayEntries = maximumArrayEntries
        self.maximumBufferBytes = maximumBufferBytes
        self.resolveMaterial = resolveMaterial
        self.admitShape = admitShape
    }
}

enum WPEParityScriptModels {
    static func perform(_ input: JSValue, token: UInt32?, path: String,
                        provider: WPEParityScriptModelDataProvider,
                        consume: (WPEParityModelDataPatch) throws -> UInt32?) -> JSValue? {
        guard let context = input.context, let result = JSValue(newObjectIn: context) else { return nil }
        do {
            let patch = try WPEModelDataConverter.convert(
                input, requireFields: token == nil, maximumArrayEntries: provider.maximumArrayEntries,
                maximumBufferBytes: provider.maximumBufferBytes,
                resolveMaterial: { try provider.resolveMaterial($0, path) }
            )
            if let created = try consume(patch) {
                result.setObject(created, forKeyedSubscript: "value" as NSString)
            }
        } catch {
            // Throw the original getter exception in JS, rather than stringify/clone it across the VM boundary.
            let exception = context.exception
            context.exception = nil
            let message: String = if let failure = error as? WPEParityModelDataFailure {
                failure.message
            } else if let failure = error as? WPEModelDataConverter.Failure {
                failure.nativeMessage ?? "ModelData safety admission: \(failure)"
            } else {
                String(describing: error)
            }
            result.setValue(exception ?? JSValue(newErrorFromMessage: message, in: context), forProperty: "error")
        }
        return result
    }

    /// Uses shipped IModelData's constants and toConfigString; only native methods/immutable internal identity are added.
    static let source = #"""
    const modelOwners = new WeakMap();
    function modelResult(result) {
      if (result && result.error !== undefined) throw result.error;
      return result ? result.value : undefined;
    }
    scene.createModelData = function(config) {
      sceneScope('createModelData');
      if (arguments.length === 0 || config === null
          || (typeof config !== 'object' && typeof config !== 'function')) return undefined;
      const token = modelResult(host.createModelData(config, current.path));
      if (token === undefined) return undefined;
      const model = Object.create(IModelData.prototype);
      Object.defineProperty(model, '__modelDataToken', { value: token, writable: true, enumerable: true, configurable: true });
      modelOwners.set(model, token);
      return model;
    };
    scene.destroyModelData = function(token) {
      sceneScope('destroyModelData');
      if (typeof token !== 'number' || !Number.isInteger(token) || token < 0 || token > 4294967295) return;
      host.releaseModelData(token);
    };
    Object.defineProperties(IModelData.prototype, {
      applyData: { value: function(config) {
        const token = modelOwners.get(this);
        if (token === undefined || arguments.length === 0) return;
        modelResult(host.updateModelData(token, config, false, current ? current.path : ''));
      }, writable: true, configurable: true },
      replaceData: { value: function(config) {
        const token = modelOwners.get(this);
        if (token === undefined || arguments.length === 0) return;
        if (currentEvent === 1) throw new Error('IModelData.replace cannot be called in update.');
        modelResult(host.updateModelData(token, config, true, current ? current.path : ''));
      }, writable: true, configurable: true }
    });
    """#
}
