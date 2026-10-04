#if DEBUG
import Foundation

@MainActor
extension QAControlPlane {
    static var libraryToolDescriptions: [[String: Any]] {
        let string: [String: Any] = ["type": "string", "maxLength": 1024]
        let screen: [String: Any] = ["type": "integer", "minimum": 0, "maximum": UInt32.max]
        let boolean: [String: Any] = ["type": "boolean"]
        let itemInput = object(["itemID": string, "expectedItemRevision": string], required: ["itemID"])
        let itemOutput = object([
            "itemID": string, "revision": string, "title": ["type": "string"],
            "sourceKind": ["type": "string", "enum": ["saved", "steam", "local", "aerial"]],
            "wallpaperType": ["type": "string", "enum": ["video", "html", "scene"]],
            "isBookmarked": boolean, "isVariant": boolean,
            "parentID": ["type": ["string", "null"]], "supported": boolean,
            "availability": ["type": "string", "enum": ["unknown", "available", "unavailable"]],
            "onDisplays": ["type": "array", "items": screen],
            "unavailableReason": ["type": ["string", "null"]],
        ], required: ["itemID", "revision", "title", "sourceKind", "wallpaperType", "supported", "availability"])
        let listInput = object([
            "source": ["type": "string", "enum": ["all", "saved", "steam", "local", "aerial"]],
            "type": ["type": "string", "enum": ["all", "video", "html", "scene"]],
            "bookmarked": boolean, "query": string,
            "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 50], "cursor": string,
        ])
        let listOutput = object([
            "items": ["type": "array", "items": itemOutput], "count": ["type": "integer"],
            "total": ["type": "integer"], "catalogRevision": string,
            "nextCursor": ["type": ["string", "null"]], "instanceID": string,
        ], required: ["items", "count", "total", "catalogRevision", "nextCursor", "instanceID"])
        let operationOutput = object([
            "operationID": string, "screenID": screen, "itemID": string, "itemRevision": string,
            "status": ["type": "string", "enum": ["pending", "running", "completed", "failed", "cancelled"]],
            "completionLevel": ["type": "string", "enum": ["committed"]],
            "createdAt": string, "result": ["type": "object", "additionalProperties": true], "waitTimedOut": boolean,
        ], required: ["operationID", "screenID", "itemID", "itemRevision", "status", "completionLevel", "createdAt", "result"])
        return [
            tool("library.list", description: "Read the full authorized library (saved content, installed Workshop/local projects and Apple Aerials), regardless of bookmark marks. Stable ID order and revision-bound pagination; availability is unknown until library.get. No grants or file paths are returned.", input: listInput, output: listOutput, readOnly: true),
            tool("library.get", description: "Read one library item and probe source access. Rejects a revision changed during the probe. Unavailable combines missing source and inaccessible grant; it does not test remote URL reachability.", input: itemInput, output: itemOutput, readOnly: true),
            tool("library.refresh", description: "Rescan already-authorized Apple Aerials and read the first library page. Does not request new file grants or migrate bookmark marks.", input: object([:]), output: listOutput, readOnly: false),
            tool("wallpaper.applyLibraryItem", description: "Apply any supported library item through the product ApplyRouter, without saving or bookmarking it. Returns an operation immediately; operation.wait/get confirms product commit, not pixels. Per-screen parameters are preserved; leaving span may affect the span group. A second apply on the same screen is refused until the current operation finishes. requestID deduplicates retries within bounded history; instanceID rejects stale app instances.", input: object(["screenID": screen, "itemID": string, "expectedItemRevision": string, "requestID": string, "instanceID": string], required: ["screenID", "itemID"]), output: operationOutput, readOnly: false),
            tool("operation.get", description: "Read retained apply results. IDs expire after app restart or bounded history eviction. completed means product commit was confirmed; inspect runtime.state and screen.capture for rendering.", input: object(["operationID": string], required: ["operationID"]), output: operationOutput, readOnly: true),
            tool("operation.wait", description: "Wait at most 10 seconds for a retained apply to finish. waitTimedOut leaves the operation running; call again. This waits for committed, not presentation.", input: object(["operationID": string, "timeoutMs": ["type": "integer", "minimum": 0, "maximum": 10000, "default": 1000]], required: ["operationID"]), output: operationOutput, readOnly: true),
            tool("playback.set", description: "Set play/pause intent explicitly through the product setter; repeats do not toggle it. Without screenID targets all screens and requires a playback controller on every target. Policies may keep playback suspended while intent is play.", input: object(["screenID": screen, "playing": boolean], required: ["playing"]), output: object(["status": ["type": "string"], "playing": boolean, "runtime": ["type": "object"]], required: ["status", "playing", "runtime"]), readOnly: false),
        ]
    }

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static func tool(_ name: String, description: String, input: [String: Any], output: [String: Any], readOnly: Bool) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": input, "outputSchema": output,
         "annotations": ["readOnlyHint": readOnly, "openWorldHint": false]]
    }
}
#endif
