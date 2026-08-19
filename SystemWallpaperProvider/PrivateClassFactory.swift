import Foundation
import IOSurface
import os.log

// Constructs instances of WallpaperExtensionKit's opaque reply classes by
// raw-writing their single boxed ivar (contract §4). Every write is bounds-
// checked against the allocated instance size and fails closed.

enum PrivateClassFactory {
    /// Byte offset of ivar `name`, or nil. No fallback: a renamed or re-laid-
    /// out ivar with the same instance size would pass the bounds check below
    /// and silently corrupt whatever field now lives at the old offset —
    /// inside WallpaperAgent's address space, not ours. Unknown layout means
    /// don't write.
    static func ivarOffset(_ cls: AnyClass, _ name: String) -> Int? {
        guard let ivar = class_getInstanceVariable(cls, name) else { return nil }
        return ivar_getOffset(ivar)
    }

    /// WallpaperRemoteContextXPC boxing a single UInt32 remote context id.
    static func remoteContext(contextId: UInt32) -> NSObject? {
        guard let cls = NSClassFromString("WallpaperRemoteContextXPC") else {
            wpxLog.error("WallpaperRemoteContextXPC missing")
            return nil
        }
        guard let instance = class_createInstance(cls, 0) as? NSObject else { return nil }
        guard let offset = ivarOffset(cls, "box") else {
            wpxLog.error("remoteContext ivar 'box' missing — layout changed")
            return nil
        }
        guard offset + MemoryLayout<UInt32>.size <= class_getInstanceSize(cls) else {
            wpxLog.error("remoteContext ivar offset OOB")
            return nil
        }
        let raw = Unmanaged.passUnretained(instance).toOpaque()
        raw.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee = contextId
        return instance
    }

    /// WallpaperSnapshotXPC boxing a retained IOSurface pointer.
    /// Ownership of the +1 retain transfers into the object.
    static func snapshot(surface: IOSurface) -> NSObject? {
        guard let cls = NSClassFromString("WallpaperSnapshotXPC") else {
            wpxLog.error("WallpaperSnapshotXPC missing")
            return nil
        }
        guard let instance = class_createInstance(cls, 0) as? NSObject else { return nil }
        guard let offset = ivarOffset(cls, "rawValue") else {
            wpxLog.error("snapshot ivar 'rawValue' missing — layout changed")
            return nil
        }
        guard offset + MemoryLayout<UnsafeRawPointer>.size <= class_getInstanceSize(cls) else {
            wpxLog.error("snapshot ivar offset OOB")
            return nil
        }
        let retained = Unmanaged.passRetained(surface).toOpaque()
        let base = Unmanaged.passUnretained(instance).toOpaque()
        base.advanced(by: offset).assumingMemoryBound(to: UnsafeRawPointer.self).pointee =
            UnsafeRawPointer(retained)
        return instance
    }
}
