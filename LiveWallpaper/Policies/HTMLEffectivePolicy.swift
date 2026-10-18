import LiveWallpaperCore

/// What a web page runs with, which is what every control for it must show.
struct HTMLEffectivePolicy: Equatable {
    /// The untrusted origin overriding the config; nil when the config's own values apply.
    let limitedBy: TrustedHTMLOrigin?
    let allowsJavaScript: Bool
    let muted: Bool

    init(config: HTMLConfig, source: HTMLSource?, trustedOrigins: Set<TrustedHTMLOrigin>) {
        let trust = source.map { HTMLTrust.evaluate(source: $0, trustedOrigins: trustedOrigins) } ?? .localContent
        limitedBy = if case let .untrustedRemote(origin) = trust {
            origin
        } else {
            nil
        }
        allowsJavaScript = trust.effectiveAllowJavaScript(requested: config.allowJavaScript)
        muted = trust.effectiveMuteAudio(requested: config.muteAudio)
    }
}
