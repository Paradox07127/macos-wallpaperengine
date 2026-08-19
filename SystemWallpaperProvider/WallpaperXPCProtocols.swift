import Foundation

// Selector names below are the wire contract with WallpaperAgent
// (.notes/plan/phosphene-xpc-contract.md §2.2) — do not rename.

@objc protocol WallpaperExtensionXPCProtocol: NSObjectProtocol {
    // Lifecycle
    @objc(acquireWithId:request:reply:)
    func acquire(id: Any?, request: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void)
    @objc(updateWithId:request:reply:)
    func update(id: Any?, request: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(invalidateWithId:reply:)
    func invalidate(id: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(snapshotWithId:reply:)
    func snapshot(id: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void)
    // Settings
    @objc(provideSettingsViewModelsWithContentTypes:reply:)
    func provideSettingsViewModels(contentTypes: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void)
    // Choices
    @objc(addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:)
    func addChoiceRequest(request: Any?, onBehalfOfProcess: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void)
    @objc(removeChoiceRequestWithChoiceRequest:reply:)
    func removeChoiceRequest(request: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(selectedChoicesDidChangeFor:reply:)
    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(invokeContextMenuActionWithMenuItemID:groupItemID:reply:)
    func invokeContextMenuAction(menuItemID: Any?, groupItemID: Any?, reply: @escaping @Sendable (Error?) -> Void)
    // Downloads
    @objc(isChoiceDownloadedWith:reply:)
    func isChoiceDownloaded(with choiceID: Any?, reply: @escaping @Sendable (Bool, Error?) -> Void)
    @objc(downloadWithChoiceID:reply:)
    func download(choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void) -> Any?
    @objc(pauseDownloadFor:reply:)
    func pauseDownload(for choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(cancelDownloadFor:reply:)
    func cancelDownload(for choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(resumeDownloadFor:reply:)
    func resumeDownload(for choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(removeDownloadFor:reply:)
    func removeDownload(for choiceID: Any?, reply: @escaping @Sendable (Error?) -> Void)
    // Migration
    @objc(migrateSelectedChoiceFor:reply:)
    func migrateSelectedChoice(for id: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void)
    @objc(migrateFrom:to:reply:)
    func migrate(from: Any?, to: Any?, reply: @escaping @Sendable (Error?) -> Void)
    // Shuffle
    @objc(skipShuffledContentWithId:reply:)
    func skipShuffledContent(id: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(canSkipShuffledContentWithId:reply:)
    func canSkipShuffledContent(id: Any?, reply: @escaping @Sendable (Bool, Error?) -> Void)
    // Debug & notifications
    @objc(handleDebugRequestFor:reply:)
    func handleDebugRequest(for request: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void)
    @objc(handleNotificationWithNamed:reply:)
    func handleNotification(named: Any?, reply: @escaping @Sendable (Error?) -> Void)
}

@objc protocol WallpaperExtensionProxyXPCProtocol: NSObjectProtocol {
    @objc(pingWithId:)
    func ping(id: Any?)
    @objc(updateSettingsViewModels:reply:)
    func updateSettingsViewModels(_ models: Any?, reply: @escaping @Sendable (Error?) -> Void)
    @objc(requestReadOnlyAccessTo:reply:)
    func requestReadOnlyAccess(to url: Any?, reply: @escaping @Sendable (Any?) -> Void)
    @objc(invalidateSnapshotsWithReply:)
    func invalidateSnapshots(reply: @escaping @Sendable (Error?) -> Void)
}
