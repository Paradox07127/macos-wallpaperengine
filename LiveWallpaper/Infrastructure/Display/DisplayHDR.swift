#if !MAS_BUILD
import CoreGraphics
import Foundation

struct DisplayHDRState: Equatable, Sendable {
    let isSupported: Bool
    let isPreferred: Bool
}

@MainActor
enum DisplayHDR {
    static func state(for display: CGDirectDisplayID) throws -> DisplayHDRState {
        let panelDisplay = try monitorPanelDisplay(for: display)
        return DisplayHDRState(
            isSupported: panelDisplay.value(forKey: "hasHDRModes") as? Bool ?? false,
            isPreferred: panelDisplay.value(forKey: "preferHDRModes") as? Bool ?? false
        )
    }

    static func setPreferred(_ preferred: Bool, for display: CGDirectDisplayID) throws {
        try monitorPanelDisplay(for: display).setValue(preferred, forKey: "preferHDRModes")
    }

    private static func monitorPanelDisplay(for display: CGDirectDisplayID) throws -> NSObject {
        // KVC on a key the class lacks raises an uncatchable ObjC exception, so the keys are probed first.
        guard DisplayPrivateSymbols.shared.isMonitorPanelLoaded,
              let managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type,
              let displayClass = NSClassFromString("MPDisplay"),
              managerClass.instancesRespond(to: NSSelectorFromString("displays")),
              ["displayID", "hasHDRModes", "preferHDRModes", "setPreferHDRModes:"].allSatisfy({
                  displayClass.instancesRespond(to: NSSelectorFromString($0))
              })
        else { throw DisplayControlError.unavailable }
        let displays = managerClass.init().value(forKey: "displays") as? [NSObject] ?? []
        guard let match = displays.first(where: { ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == display }) else {
            throw DisplayControlError.displayNotFound
        }
        return match
    }
}
#endif
