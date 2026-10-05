#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Repairs camera-parallax envelopes only when a property explicitly names
/// the field or has a recognized author label. Declaration and script order
/// are not evidence of a binding; unrelated or ambiguous sliders stay untouched.
enum WPESceneParallaxBindingInference {
    private static let fieldLabels: [String: Set<String>] = [
        "cameraparallaxamount": ["镜头视差"],
        "cameraparallaxmouseinfluence": ["鼠标影响"],
        "cameraparallaxdelay": [],
    ]

    static func applying(
        to data: Data,
        schema: WallpaperEngineProjectPropertySchema
    ) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var general = root["general"] as? [String: Any] else { return data }
        guard let source = String(bytes: data, encoding: .utf8) else { return data }
        var boundKeys: Set<String> = []
        func collectBindings(in value: Any) {
            if let object = value as? [String: Any] {
                if let key = object["user"] as? String {
                    boundKeys.insert(key)
                }
                for child in object.values {
                    collectBindings(in: child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    collectBindings(in: child)
                }
            }
        }
        collectBindings(in: root)
        var didRepair = false
        for (field, labels) in fieldLabels {
            guard let fallback = general[field], !(fallback is [String: Any]),
                  source.contains("thisScene.\(field)") else { continue }
            let candidates = schema.properties.filter {
                $0.type == .slider && !boundKeys.contains($0.key)
                    && ($0.key == field || labels.contains($0.displayText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            guard candidates.count <= 1 else { return data }
            guard let property = candidates.first else { continue }
            general[field] = ["user": property.key, "value": fallback]
            boundKeys.insert(property.key)
            didRepair = true
        }
        guard didRepair else { return data }
        root["general"] = general
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }
}
#endif
