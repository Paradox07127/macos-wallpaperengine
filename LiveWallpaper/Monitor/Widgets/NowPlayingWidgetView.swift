import SwiftUI
import ImageIO
import LiveWallpaperCore

// MARK: - Pure layout decision (invariant 9: field-driven, tested)

/// What a Now Playing tile renders, decided only by which fields the state
/// carries, the tile size, the chosen style, and edit/motion context —
/// never by which player produced the state.
struct NowPlayingWidgetLayout: Equatable {
    enum Component: Hashable, Sendable {
        case placeholder      // edit-mode stand-in while no track is available
        case artworkThumb     // poster: small rounded cover beside the type block
        case disc             // vinyl: the record itself (plain platter when no artwork)
        case discArtwork      // vinyl: artwork inside the platter
        case glow             // aurora: accent radial halo
        case title
        case artistLine
        case albumLine
        case progress         // poster hairline / vinyl ring / aurora microline
        case timeText         // poster: elapsed/total · vinyl: total on the album line
        case controls         // transport buttons, revealed under the pointer
        case lyrics           // synced words under the type block
    }

    /// Which transport buttons a tile of this size has room for.
    enum ControlButton: Hashable, Sendable {
        case previous, playPause, next
    }

    var renders: Bool
    var visible: Set<Component>
    /// Any animation allowed (disc spin, entrance, glow pulse).
    var motion: Bool
    /// Paused presentation: whole tile dims, all motion frozen.
    var dimmed: Bool
    /// Long titles may loop horizontally: asked for *and* otherwise in motion.
    var marquee: Bool
    /// Whether the transport row occupies space at all — everything the
    /// `.controls` component needs except the pointer. The row is laid out
    /// whenever this is true and merely fades with hover, so arriving with the
    /// pointer never reflows the tile out from under a click.
    var controlsAllowed: Bool
    /// The progress line accepts a scrub: it is on screen, the user allowed it,
    /// the player can be driven, and a duration exists to scrub against.
    var seekable: Bool

    /// Visibility is the AND of two independent questions: does the player
    /// carry the field at all, and does the user want to see it. Either one
    /// saying no leaves the component out entirely — a field the player never
    /// sent still never becomes a placeholder just because its switch is on.
    nonisolated static func resolve(
        state: MonitorNowPlayingState?,
        size: MusicOverlaySize,
        options: NowPlayingOptions,
        isEditing: Bool,
        reduceMotion: Bool,
        canControl: Bool = false,
        hovering: Bool = false,
        hasLyrics: Bool = false
    ) -> NowPlayingWidgetLayout {
        guard state?.phase.hasTrack == true, let state else {
            // Invisible off-duty; edit mode still needs a drag target.
            return NowPlayingWidgetLayout(
                renders: isEditing,
                visible: isEditing ? [.placeholder] : [],
                motion: false,
                dimmed: false,
                marquee: false,
                controlsAllowed: false,
                seekable: false
            )
        }

        let paused = state.phase == .paused
        let compact = size == .small
        let hasArtwork = state.artwork?.isEmpty == false && options.showArtwork
        let hasArtist = state.artist?.isEmpty == false && options.showArtist
        let hasAlbum = state.album?.isEmpty == false && options.showAlbum
        let hasPosition = state.position != nil && options.showProgress

        var visible: Set<Component> = [.title]
        switch options.style {
        case .poster:
            if hasArtist { visible.insert(.artistLine) }
            if hasAlbum, !compact { visible.insert(.albumLine) }
            if hasArtwork, !compact { visible.insert(.artworkThumb) }
            if hasPosition { visible.insert(.progress) }
            // Poster's readout is elapsed/total, so it belongs to the progress
            // switch; vinyl's below is the total length alone and does not.
            if hasPosition, state.duration != nil { visible.insert(.timeText) }
        case .vinyl:
            visible.insert(.disc)
            if hasArtwork { visible.insert(.discArtwork) }
            if hasArtist, !compact { visible.insert(.artistLine) }
            if hasAlbum, !compact { visible.insert(.albumLine) }
            if state.duration != nil, !compact { visible.insert(.timeText) }
            if hasPosition { visible.insert(.progress) }
        case .aurora:
            if !paused { visible.insert(.glow) }  // paused: halo goes dark, text remains
            if hasArtist, !compact { visible.insert(.artistLine) }
            if hasPosition { visible.insert(.progress) }
        }

        // Same AND rule again: the track must have lyrics and the user must want
        // them. A small tile has no room for a line of text under the title, so
        // it never carries the component at any setting.
        if hasLyrics, options.showLyrics, !compact { visible.insert(.lyrics) }

        // Same AND rule as every other component, with the pointer as a third
        // term: the player must be drivable, the user must have left the
        // switch on, and the pointer must be over the tile. Edit mode is out —
        // there a click means "grab this layer", and the board's own drag
        // gesture runs alongside subview gestures, so a button under the
        // pointer would fire while the user was only trying to move the tile.
        if canControl, options.showControls, hovering, !isEditing { visible.insert(.controls) }

        let motion = state.phase == .playing && !reduceMotion
        return NowPlayingWidgetLayout(
            renders: true,
            visible: visible,
            motion: motion,
            dimmed: paused,
            marquee: options.marquee && motion,
            controlsAllowed: canControl && options.showControls && !isEditing,
            seekable: visible.contains(.progress)
                && options.style.drawsLinearProgress
                && options.seekOnProgressDrag
                && canControl
                && !isEditing
                && (state.duration ?? 0) > 0
        )
    }

    /// A small tile has room for one button; anything larger gets all three.
    nonisolated static func controlButtons(for size: MusicOverlaySize) -> [ControlButton] {
        size == .small ? [.playPause] : [.previous, .playPause, .next]
    }

    /// Lyric rows a tile of this size draws. Only the large tile has the height
    /// for the surrounding pair, so the row-count option applies there alone.
    nonisolated static func lyricsLineCount(
        for size: MusicOverlaySize, options: NowPlayingOptions
    ) -> Int {
        switch size {
        case .large: options.lyricsLines
        case .medium: 1
        case .small: 0
        }
    }

    /// Wall-clock interpolation (invariant 5): the source only stores
    /// `position` + `positionSampledAt`; only a playing track advances,
    /// clamped to the reported duration.
    nonisolated static func interpolatedPosition(state: MonitorNowPlayingState, now: Date) -> Double? {
        guard let position = state.position else { return nil }
        var value = position
        if state.phase == .playing, let sampledAt = state.positionSampledAt {
            value += max(0, now.timeIntervalSince1970 - sampledAt)
        }
        if let duration = state.duration { value = min(value, duration) }
        return max(0, value)
    }

    /// Where a landed seek believes the playhead is, until the player says
    /// otherwise. Spotify does not always announce a scrub, so the draft has to
    /// keep running on the same wall clock as the real position — and it has to
    /// yield the moment a report sampled *after* the drag arrives, otherwise a
    /// track change would keep drawing the old track's offset.
    struct SeekDraft: Equatable {
        var seconds: Double
        var landedAt: Date
    }

    nonisolated static func displayPosition(
        state: MonitorNowPlayingState, draft: SeekDraft?, now: Date
    ) -> Double? {
        guard let draft else { return interpolatedPosition(state: state, now: now) }
        if let sampledAt = state.positionSampledAt, sampledAt > draft.landedAt.timeIntervalSince1970 {
            return interpolatedPosition(state: state, now: now)
        }
        var value = draft.seconds
        if state.phase == .playing { value += max(0, now.timeIntervalSince(draft.landedAt)) }
        if let duration = state.duration { value = min(value, duration) }
        return max(0, value)
    }

    /// What a finished seek command should do to the optimistic playhead.
    enum SeekOutcome: Equatable {
        /// Show this draft: the player took the position, or already has it.
        case commit(SeekDraft)
        /// Drop the draft and snap back to whatever the player reports.
        case discard
        /// Another track is on screen now — touch nothing.
        case ignore
    }

    /// `throttled` means the identical seek was sent moments ago and this one
    /// was suppressed, so the position the user asked for *is* in flight;
    /// treating it as a failure snapped the playhead back to the old spot.
    nonisolated static func seekOutcome(
        failure: NowPlayingControlFailure?,
        committedKey: String,
        currentKey: String,
        seconds: Double,
        landedAt: Date
    ) -> SeekOutcome {
        guard committedKey == currentKey else { return .ignore }
        switch failure {
        case .none, .throttled:
            return .commit(SeekDraft(seconds: seconds, landedAt: landedAt))
        default:
            return .discard
        }
    }
}

// MARK: - View (borderless art layer — no container, no header, no panel)

struct NowPlayingWidgetView: View {
    let context: MusicOverlayContext

    @Environment(\.monitorSuspended) private var suspended
    @State private var accent: NowPlayingAccentColor?
    @State private var lyrics: [LyricLine] = []
    @State private var discAngle: Double = 0
    @State private var glowBoost = false
    @State private var hovering = false
    /// Non-nil only while a scrub is under the pointer.
    @State private var scrubFraction: Double?
    /// Non-nil after a scrub landed, until the player reports a fresher position.
    @State private var seekDraft: NowPlayingWidgetLayout.SeekDraft?
    @State private var showsPermissionNotice = false
    /// Discriminates overlapping auto-dismiss timers for the notice.
    @State private var permissionNoticeToken = 0

    // MARK: Style option (persisted in placement.options)

    enum Style: String, CaseIterable, Sendable {
        case poster, vinyl, aurora

        /// Poster and aurora draw progress as a horizontal bar, which a pointer
        /// can scrub along. Vinyl draws it as a ring around a spinning platter:
        /// dragging that would mean an angular grab on moving art, so the ring
        /// stays a readout.
        var drawsLinearProgress: Bool { self != .vinyl }
    }

    nonisolated static func style(_ options: [String: MonitorWidgetOptionValue]) -> Style {
        NowPlayingOptions(options).style
    }

    static func styleDisplayName(_ style: Style) -> String {
        switch style {
        case .poster: return String(localized: "Poster", comment: "Now Playing widget style: typographic poster layer.")
        case .vinyl: return String(localized: "Vinyl", comment: "Now Playing widget style: spinning record.")
        case .aurora: return String(localized: "Aurora", comment: "Now Playing widget style: minimal text with a glow.")
        }
    }

    // MARK: Derived

    private var state: MonitorNowPlayingState? { context.snapshot.nowPlaying }
    private var options: NowPlayingOptions { NowPlayingOptions(context.options) }
    private var style: Style { options.style }
    private var layout: NowPlayingWidgetLayout {
        NowPlayingWidgetLayout.resolve(
            state: state,
            size: context.size,
            options: options,
            isEditing: context.isEditing,
            reduceMotion: context.reduceMotion,
            canControl: canControl,
            hovering: hovering,
            hasLyrics: !lyrics.isEmpty
        )
    }

    /// Whether this player has a control vocabulary at all. Same table shape as
    /// the ingest and artwork routes: a lookup, never a branch on the player.
    private var canControl: Bool {
        NowPlayingControlMapping.mapping(for: state?.playerBundleID) != nil
    }

    /// Track identity for entrance emphasis + artwork/accent caches.
    /// trackID when the player reports one, else the textual identity —
    /// album included so same-title/same-artist tracks on different albums
    /// (a real Apple Music case) refresh their artwork and accent.
    private var trackKey: String {
        guard let state else { return "" }
        return state.trackID ?? "\(state.title)|\(state.artist ?? "")|\(state.album ?? "")"
    }

    /// Accent must recompute when the artwork arrives on a later frame of the
    /// same track (the fetcher publishes text first, image afterwards).
    private var accentTaskKey: String {
        "\(trackKey)|\(state?.artwork == nil ? 0 : 1)"
    }

    /// Turning the switch on must fetch for the track already on screen, so the
    /// option is part of the key rather than only a render-time filter.
    private var lyricsTaskKey: String {
        "\(trackKey)|\(options.showLyrics ? 1 : 0)"
    }

    private var accentColor: Color {
        NowPlayingOptions.resolvedAccent(options: options, artwork: accent)?.color ?? Design.signalAmber
    }

    /// Text alphas are authored per role (0.97 title, 0.74 eyebrow …); the
    /// brightness dial scales all of them by one factor rather than restating
    /// each role's ramp.
    private func textAlpha(_ base: Double) -> Double { base * options.textBrightness }

    private var titleDesign: Font.Design { options.resolvedTitleFont.design }
    private var alignment: NowPlayingOptions.Alignment { options.resolvedAlignment }

    /// Scrolling also needs the tile to be awake — `layout.marquee` already
    /// folds in reduce-motion and pause, but not the board's suspend gate.
    private var marqueeActive: Bool { layout.marquee && !suspended }

    /// Interpolated elapsed seconds at the current board tick (nil without a
    /// live position); a scrub under the pointer or a landed seek wins over it.
    private var elapsed: Double? {
        guard let state else { return nil }
        if let scrubFraction, let duration = state.duration {
            return scrubFraction * duration
        }
        return NowPlayingWidgetLayout.displayPosition(state: state, draft: seekDraft, now: context.now)
    }

    private var progressFraction: Double {
        if let scrubFraction { return min(max(scrubFraction, 0), 1) }
        guard let elapsed, let duration = state?.duration, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    /// The 1 Hz tween must not lag a scrub that is following the pointer.
    private var liveProgressAnimation: Animation? {
        scrubFraction == nil ? progressAnimation : nil
    }

    /// Audio-layer gate, re-read on the 1Hz board tick; Lite ships no capture
    /// pipeline, so the layer never exists there.
    private var audioActive: Bool {
        #if !LITE_BUILD
        return NowPlayingAudioLayer.shouldRun(
            phase: state?.phase,
            reduceMotion: context.reduceMotion,
            suspended: suspended,
            capturing: SystemAudioCaptureManager.shared.state == .capturing,
            audioReactive: options.audioReactive
        )
        #else
        return false
        #endif
    }

    // MARK: Body

    var body: some View {
        if layout.renders {
            GeometryReader { geo in
                if layout.visible.contains(.placeholder) {
                    editPlaceholder(in: geo.size)
                } else if let state {
                    ZStack {
                        trackContent(state: state, in: geo.size)
                            .id(trackKey)
                            .transition(entranceTransition)
                    }
                    .animation(layout.motion ? .easeOut(duration: 0.4) : nil, value: trackKey)
                    .opacity(layout.dimmed ? 0.55 : 1)
                    .overlay { transportOverlay(state: state, in: geo.size) }
                    .overlay(alignment: .bottom) { permissionNotice(in: geo.size) }
                    .task(id: accentTaskKey) { await refreshAccent(for: state) }
                    .task(id: lyricsTaskKey) { await refreshLyrics(for: state) }
                    .onChange(of: trackKey) { _, _ in
                        pulseGlow()
                        seekDraft = nil   // a scrub aimed at the previous track
                    }
                    .onChange(of: context.now) { _, _ in advanceDisc() }
                }
            }
            .opacity(options.opacity)
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.2)) { hovering = inside }
            }
        }
    }

    /// One-shot, self-dismissing, never a dialog: the layer is wallpaper, and a
    /// modal from the desktop would be worse than an inert button.
    @ViewBuilder
    private func permissionNotice(in size: CGSize) -> some View {
        if showsPermissionNotice {
            Text("Allow control in System Settings → Privacy & Security → Automation.")
                .font(.system(size: max(9, min(13, size.height * 0.06)), weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.55))
                )
                .padding(6)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// One title renderer for all three styles: the marquee replaces the
    /// truncating label only while it is allowed to move.
    @ViewBuilder
    private func titleText(
        _ text: String, size: CGFloat, weight: Font.Weight, lineLimit: Int, minimumScale: CGFloat
    ) -> some View {
        let font = Font.system(size: size, weight: weight, design: titleDesign)
        let color = Color.white.opacity(textAlpha(0.97))
        if marqueeActive {
            NowPlayingMarqueeText(text: text, font: font, color: color)
        } else {
            Text(verbatim: text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .minimumScaleFactor(minimumScale)
                .multilineTextAlignment(alignment.text)
        }
    }

    /// Change-of-track emphasis: rise 8pt + fade in over 0.4s, then rest.
    private var entranceTransition: AnyTransition {
        guard layout.motion else { return .identity }
        return .asymmetric(
            insertion: .offset(y: 8).combined(with: .opacity),
            removal: .opacity
        )
    }

    @ViewBuilder
    private func trackContent(state: MonitorNowPlayingState, in size: CGSize) -> some View {
        switch style {
        case .poster: posterBody(state: state, in: size)
        case .vinyl: vinylBody(state: state, in: size)
        case .aurora: auroraBody(state: state, in: size)
        }
    }

    // MARK: Motion drivers

    private func refreshAccent(for state: MonitorNowPlayingState) async {
        guard let artwork = state.artwork, !artwork.isEmpty else {
            accent = nil
            return
        }
        let value = await NowPlayingAccentStore.shared.accent(for: trackKey, data: artwork)
        // .task(id:) cancelled us if the track changed while extracting; a
        // slow track-A extraction must not repaint track B's accent.
        guard !Task.isCancelled else { return }
        accent = value
    }

    private func refreshLyrics(for state: MonitorNowPlayingState) async {
        guard options.showLyrics else {
            lyrics = []
            return
        }
        let value = await NowPlayingLyricsStore.shared.lyrics(for: state)
        // Same discipline as the accent: a slow track-A fetch must not paint
        // track B's rows.
        guard !Task.isCancelled else { return }
        lyrics = value
    }

    // MARK: Lyrics

    @ViewBuilder
    private func lyricsLayer(fontSize: CGFloat) -> some View {
        if layout.visible.contains(.lyrics) {
            NowPlayingLyricsView(
                lines: lyrics,
                lineCount: NowPlayingWidgetLayout.lyricsLineCount(
                    for: context.size, options: options
                ),
                playhead: lyricsPlayhead,
                accent: accentColor,
                alignment: alignment,
                fontSize: fontSize,
                brightness: options.textBrightness,
                wordTimed: lyrics.contains { $0.words != nil }
            )
            .nowPlayingTextShadow()
        }
    }

    /// nil when the player never reports a position — there is no timeline to
    /// follow then, and the rows fall back to a still opening block.
    private var lyricsPlayhead: NowPlayingLyricsView.Playhead? {
        guard let elapsed else { return nil }
        return NowPlayingLyricsView.Playhead(
            position: elapsed, date: context.now, advancing: layout.motion && !suspended
        )
    }

    /// ~8s per revolution at the 1Hz board clock; pausing simply stops advancing,
    /// which freezes the platter at its current angle.
    private func advanceDisc() {
        guard style == .vinyl, layout.motion, !suspended else { return }
        withAnimation(.linear(duration: 1)) { discAngle += 45 }
    }

    /// Aurora: instant brighten on track change, 0.6s fall back.
    private func pulseGlow() {
        guard style == .aurora, layout.motion else { return }
        glowBoost = true
        withAnimation(.easeOut(duration: 0.6)) { glowBoost = false }
    }

    /// Progress shapes tween between 1Hz ticks; frozen when not playing.
    private var progressAnimation: Animation? {
        layout.motion ? .linear(duration: 1) : nil
    }

    // MARK: Transport controls

    /// Hidden until the pointer arrives, so the resting layer stays a piece of
    /// type rather than a player widget.
    ///
    /// An overlay, never a row in the style's stack. Two reasons, both learned
    /// the hard way: in the flow it reflowed the tile on hover and slid itself
    /// out from under the click, and on a one-cell-tall tile the stack
    /// overflowed the widget rect — which is precisely the region the overlay
    /// window hit-tests, so the buttons were both invisible to the pointer and
    /// able to cancel their own hover. Centred in the tile it is always inside
    /// that rect, and hover cannot be lost by walking towards it.
    @ViewBuilder
    private func transportOverlay(state: MonitorNowPlayingState, in size: CGSize) -> some View {
        if layout.controlsAllowed {
            let shown = layout.visible.contains(.controls)
            let side = min(max(min(size.width, size.height) * 0.19, 22), 46)
            HStack(spacing: side * 0.4) {
                ForEach(NowPlayingWidgetLayout.controlButtons(for: context.size), id: \.self) { button in
                    controlButton(button, state: state, side: side)
                }
            }
            .padding(.horizontal, side * 0.5)
            .padding(.vertical, side * 0.28)
            // A scrim of its own, so the buttons read over artwork, type or
            // whatever wallpaper shows through the layer.
            .background(
                Capsule().fill(.black.opacity(0.34))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
        }
    }

    private func controlButton(
        _ button: NowPlayingWidgetLayout.ControlButton,
        state: MonitorNowPlayingState,
        side: CGFloat
    ) -> some View {
        Button {
            send(Self.command(for: button), state: state)
        } label: {
            Image(systemName: Self.symbol(for: button, phase: state.phase))
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(textAlpha(0.92)))
                .frame(width: side, height: side)
                .background(Circle().fill(.black.opacity(0.3)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.controlLabel(for: button))
    }

    private static func command(for button: NowPlayingWidgetLayout.ControlButton) -> NowPlayingCommand {
        switch button {
        case .previous: .previous
        case .playPause: .playPause
        case .next: .next
        }
    }

    private static func symbol(
        for button: NowPlayingWidgetLayout.ControlButton, phase: MonitorNowPlayingPhase
    ) -> String {
        switch button {
        case .previous: "backward.end.fill"
        case .playPause: phase == .playing ? "pause.fill" : "play.fill"
        case .next: "forward.end.fill"
        }
    }

    private static func controlLabel(for button: NowPlayingWidgetLayout.ControlButton) -> Text {
        switch button {
        case .previous: Text("Previous track")
        case .playPause: Text("Play or pause")
        case .next: Text("Next track")
        }
    }

    private func send(_ command: NowPlayingCommand, state: MonitorNowPlayingState) {
        Task { @MainActor in
            let result = await NowPlayingController.shared.send(
                command, to: state.playerBundleID, duration: state.duration
            )
            if case .failure(.notAuthorized) = result { showPermissionNotice() }
        }
    }

    private func showPermissionNotice() {
        permissionNoticeToken &+= 1
        let token = permissionNoticeToken
        withAnimation(.easeOut(duration: 0.2)) { showsPermissionNotice = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard token == permissionNoticeToken else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsPermissionNotice = false }
        }
    }

    // MARK: Scrub

    /// Poster's hairline and aurora's microline are one control at two weights.
    /// The knob and the taller hit area exist only where a scrub is possible;
    /// the padding is undone straight afterwards so layout never moves.
    @ViewBuilder
    private func linearProgress(
        state: MonitorNowPlayingState, height: CGFloat, trackOpacity: Double
    ) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(trackOpacity))
                Rectangle()
                    .fill(accentColor)
                    .frame(width: g.size.width * progressFraction)
                    .animation(liveProgressAnimation, value: progressFraction)
            }
            .overlay(alignment: .leading) {
                if layout.seekable, hovering {
                    let knob = max(7.0, height * 3.5)
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .offset(x: g.size.width * progressFraction - knob / 2)
                        .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
            .gesture(
                seekDrag(width: g.size.width, state: state),
                including: layout.seekable ? .all : .none
            )
        }
        .frame(height: height)
    }

    private func seekDrag(width: CGFloat, state: MonitorNowPlayingState) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                scrubFraction = min(max(value.location.x / width, 0), 1)
            }
            .onEnded { value in
                guard width > 0 else {
                    scrubFraction = nil
                    return
                }
                let fraction = min(max(value.location.x / width, 0), 1)
                scrubFraction = fraction
                commitSeek(fraction: fraction, state: state)
            }
    }

    /// One command per drag, at the end. The optimistic position is kept only
    /// if the player actually took it — a refusal snaps back to the truth.
    private func commitSeek(fraction: Double, state: MonitorNowPlayingState) {
        guard let duration = state.duration, duration > 0 else {
            scrubFraction = nil
            return
        }
        let seconds = fraction * duration
        let landedAt = Date()
        let committedKey = trackKey
        Task { @MainActor in
            let result = await NowPlayingController.shared.send(
                .seek(seconds: seconds), to: state.playerBundleID, duration: duration
            )
            var failure: NowPlayingControlFailure?
            if case let .failure(reason) = result { failure = reason }
            switch NowPlayingWidgetLayout.seekOutcome(
                failure: failure,
                committedKey: committedKey,
                currentKey: trackKey,
                seconds: seconds,
                landedAt: landedAt
            ) {
            case let .commit(draft):
                seekDraft = draft
            case .discard:
                seekDraft = nil
                if failure == .notAuthorized { showPermissionNotice() }
            case .ignore:
                break
            }
            // Always released, including on `.ignore`: the pointer is long gone,
            // and a stuck scrub fraction would freeze the bar on the new track.
            scrubFraction = nil
        }
    }

    // MARK: Style A · poster (typographic layers, bottom-leading)

    @ViewBuilder
    private func posterBody(state: MonitorNowPlayingState, in size: CGSize) -> some View {
        let titleSize = min(52, max(17, size.height * (context.size == .large ? 0.16 : 0.30)))
            * options.titleScale
        let eyebrowSize = max(10, titleSize * 0.28)
        let inset = max(10, size.height * 0.07)
        let artworkSide = titleSize * 1.15 * options.artworkScale

        HStack(alignment: .top, spacing: layout.visible.contains(.artworkThumb) ? eyebrowSize * 0.9 : 0) {
            if layout.visible.contains(.artworkThumb), let artwork = state.artwork {
                NowPlayingArtworkView(data: artwork, cacheKey: trackKey, shape: artworkShape(radius: 4))
                    .frame(width: artworkSide, height: artworkSide)
                    .shadow(color: .black.opacity(options.artworkShadow), radius: 7, x: 0, y: 2)
            }

            VStack(alignment: alignment.horizontal, spacing: eyebrowSize * 0.5) {
                if let eyebrow = posterEyebrow(state: state) {
                    Text(verbatim: eyebrow)
                        .font(.system(size: eyebrowSize, weight: .semibold, design: .default))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(textAlpha(0.74)))
                        .lineLimit(1)
                        .nowPlayingTextShadow()
                }

                titleText(
                    state.title,
                    size: titleSize,
                    weight: .bold,
                    lineLimit: context.size == .small ? 1 : 2,
                    minimumScale: 0.7
                )
                .nowPlayingTextShadow()

                // Spectrum bars sit right above the progress line, or take its
                // place at the bottom of the type block when there is none.
                #if !LITE_BUILD
                if audioActive {
                    NowPlayingAudioReactiveView(
                        mode: .bars, accent: accentColor, active: true, options: options
                    )
                    .frame(height: max(8, titleSize * 0.6))
                        .padding(.top, eyebrowSize * 0.3)
                }
                #endif

                if layout.visible.contains(.progress) {
                    posterProgress(state: state, eyebrowSize: eyebrowSize)
                        .padding(.top, eyebrowSize * 0.3)
                }

                lyricsLayer(fontSize: eyebrowSize * 1.05)
                    .padding(.top, eyebrowSize * 0.4)

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.bottomFrame)
        .padding(inset)
    }

    /// Cover clipping. Square is the zero-radius end of the same rounded shape,
    /// so the artwork view keeps one code path.
    private func artworkShape(radius: CGFloat) -> NowPlayingArtworkView.ArtworkShape {
        switch options.artworkShape {
        case .rounded: .rounded(radius)
        case .circle: .circle
        case .square: .rounded(0)
        }
    }

    /// First typographic line: ARTIST — ALBUM, from whichever fields exist.
    private func posterEyebrow(state: MonitorNowPlayingState) -> String? {
        var parts: [String] = []
        if layout.visible.contains(.artistLine), let artist = state.artist { parts.append(artist) }
        if layout.visible.contains(.albumLine), let album = state.album { parts.append(album) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " — ").uppercased()
    }

    @ViewBuilder
    private func posterProgress(state: MonitorNowPlayingState, eyebrowSize: CGFloat) -> some View {
        HStack(spacing: eyebrowSize * 0.8) {
            linearProgress(state: state, height: 2, trackOpacity: 0.22)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 1)

            if layout.visible.contains(.timeText), let elapsed, let duration = state.duration {
                Text(verbatim: "\(Format.mmss(elapsed)) / \(Format.mmss(duration))")
                    .font(.system(size: max(9, eyebrowSize * 0.9), weight: .medium, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(textAlpha(0.68)))
                    .fixedSize()
                    .nowPlayingTextShadow()
            }
        }
    }

    // MARK: Style B · vinyl (spinning record + type column)

    @ViewBuilder
    private func vinylBody(state: MonitorNowPlayingState, in size: CGSize) -> some View {
        let inset = max(8, size.height * 0.06)
        let discSide = min(size.height - inset * 2, size.width * 0.42)
        let titleSize = min(30, max(14, size.height * (context.size == .large ? 0.10 : 0.20)))
            * options.titleScale
        let smallSize = max(10, titleSize * 0.55)

        HStack(spacing: inset * 1.4) {
            vinylDisc(state: state, side: discSide)

            VStack(alignment: alignment.horizontal, spacing: smallSize * 0.55) {
                titleText(state.title, size: titleSize, weight: .semibold, lineLimit: 2, minimumScale: 0.75)
                    .nowPlayingTextShadow()

                if layout.visible.contains(.artistLine), let artist = state.artist {
                    Text(verbatim: artist.uppercased())
                        .font(.system(size: smallSize, weight: .semibold))
                        .tracking(2.5)
                        .foregroundStyle(.white.opacity(textAlpha(0.72)))
                        .lineLimit(1)
                        .nowPlayingTextShadow()
                }

                if let footer = vinylFooter(state: state) {
                    Text(verbatim: footer)
                        .font(.system(size: smallSize * 0.95, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(textAlpha(0.55)))
                        .lineLimit(1)
                        .nowPlayingTextShadow()
                }

                lyricsLayer(fontSize: smallSize)
                    .padding(.top, smallSize * 0.3)

            }
            .frame(maxWidth: .infinity, alignment: alignment.frame)
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Album + total length share one quiet line; either half stands alone.
    private func vinylFooter(state: MonitorNowPlayingState) -> String? {
        var parts: [String] = []
        if layout.visible.contains(.albumLine), let album = state.album { parts.append(album) }
        if layout.visible.contains(.timeText), let duration = state.duration { parts.append(Format.mmss(duration)) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func vinylDisc(state: MonitorNowPlayingState, side: CGFloat) -> some View {
        ZStack {
            // Progress ring rides the platter's outer edge (does not rotate).
            if layout.visible.contains(.progress) {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(progressAnimation, value: progressFraction)
            }

            ZStack {
                Circle().fill(
                    RadialGradient(
                        colors: [Color(white: 0.16), Color(white: 0.05)],
                        center: .center, startRadius: side * 0.1, endRadius: side * 0.5
                    )
                )
                // Grooves.
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                        .padding(side * (0.06 + 0.055 * CGFloat(ring)))
                }

                if layout.visible.contains(.discArtwork), let artwork = state.artwork {
                    let label = side * discArtworkFraction
                    NowPlayingArtworkView(
                        data: artwork, cacheKey: trackKey, shape: artworkShape(radius: label * 0.12)
                    )
                    .frame(width: label, height: label)
                } else {
                    // Plain platter label when the player sends no cover.
                    Circle()
                        .fill(accentColor.opacity(0.75))
                        .frame(width: side * 0.34, height: side * 0.34)
                }

                Circle()
                    .fill(Color(white: 0.02))
                    .frame(width: side * 0.055, height: side * 0.055)
            }
            .padding(4)
            .rotationEffect(.degrees(discAngle))
        }
        .frame(width: side, height: side)
        .overlay { vinylAudioOverlay(side: side) }
        .shadow(color: .black.opacity(discShadowOpacity), radius: 10, x: 0, y: 3)
    }

    /// Label size as a fraction of the platter. A circle may fill most of it;
    /// a square's corners reach √2 further, so it is capped below the grooves.
    private var discArtworkFraction: CGFloat {
        let scaled = 0.58 * options.artworkScale
        return min(scaled, options.artworkShape == .circle ? 0.9 : 0.7)
    }

    /// The slider is calibrated on the poster thumb, which rests at 0.45 while
    /// the platter rests at 0.5; the ratio keeps both at their shipped strength
    /// when the slider is untouched, instead of paying for a second key.
    private var discShadowOpacity: Double {
        min(1, options.artworkShadow * (0.5 / NowPlayingOptions.Defaults.artworkShadow))
    }

    /// Radial spectrum outside the progress ring; the overlay frame is larger
    /// than the platter so spikes never clip, without inflating the layout.
    @ViewBuilder
    private func vinylAudioOverlay(side: CGFloat) -> some View {
        #if !LITE_BUILD
        if audioActive {
            NowPlayingAudioReactiveView(
                mode: .radial(discFraction: 1 / 1.3),
                accent: accentColor,
                active: true,
                options: options
            )
            .frame(width: side * 1.3, height: side * 1.3)
        }
        #endif
    }

    // MARK: Style C · aurora (minimal text over an accent halo)

    @ViewBuilder
    private func auroraBody(state: MonitorNowPlayingState, in size: CGSize) -> some View {
        let titleSize = min(30, max(14, size.height * (context.size == .large ? 0.11 : 0.22)))
            * options.titleScale
        let smallSize = max(10, titleSize * 0.55)

        ZStack {
            if layout.visible.contains(.glow) {
                Circle()
                    .fill(accentColor)
                    .frame(width: size.width * 0.75, height: size.width * 0.75)
                    .blur(radius: max(24, size.height * 0.28))
                    .opacity(glowBoost ? 0.55 : 0.3)
            }

            VStack(alignment: alignment.horizontal, spacing: smallSize * 0.55) {
                titleText(state.title, size: titleSize, weight: .semibold, lineLimit: 2, minimumScale: 0.75)
                    .nowPlayingTextShadow()

                if layout.visible.contains(.artistLine), let artist = state.artist {
                    Text(verbatim: artist.uppercased())
                        .font(.system(size: smallSize, weight: .semibold))
                        .tracking(2.5)
                        .foregroundStyle(.white.opacity(textAlpha(0.7)))
                        .lineLimit(1)
                        .nowPlayingTextShadow()
                }

                lyricsLayer(fontSize: smallSize)
                    .padding(.top, smallSize * 0.3)

                if layout.visible.contains(.progress) {
                    linearProgress(state: state, height: 1, trackOpacity: 0.18)
                        .frame(width: min(size.width * 0.4, 160))
                        .padding(.top, smallSize * 0.4)
                }

            }
            .padding(max(8, size.height * 0.08))

            audioReactiveSlot
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()  // halo blur must not bleed past the tile
    }

    /// Audio-reactive halo breathing + drifting motes; exists only while the
    /// audio gates pass (field-driven — silence means no layer at all).
    @ViewBuilder
    private var audioReactiveSlot: some View {
        #if !LITE_BUILD
        if audioActive {
            NowPlayingAudioReactiveView(
                mode: .aurora, accent: accentColor, active: true, options: options
            )
        }
        #endif
    }

    // MARK: Edit-mode placeholder (only visible while editing with no track)

    private func editPlaceholder(in size: CGSize) -> some View {
        let base = min(size.height, size.width)
        return VStack(spacing: max(4, base * 0.05)) {
            Image(systemName: "music.note")
                .font(.system(size: max(14, base * 0.18), weight: .light))
                .foregroundStyle(.white.opacity(0.55))
            Text(verbatim: Self.styleDisplayName(style))
                .font(.system(size: max(10, base * 0.09), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    .white.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                .padding(2)
        )
        .nowPlayingTextShadow()
    }
}

// MARK: - Marquee (opt-in horizontal loop for long titles)

/// A title too wide for its tile loops sideways instead of truncating.
///
/// Driven by a single repeating SwiftUI animation started on appear — no timer,
/// and nothing to tear down. The caller only mounts this while motion is
/// allowed, so reduce-motion, paused and suspended all fall back to the plain
/// truncating label; a title that already fits never scrolls either.
private struct NowPlayingMarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    /// Points per second — slow enough to read from across a room.
    private let speed: Double = 30
    /// Blank run between the tail of one pass and the head of the next.
    private let gap: CGFloat = 44

    @State private var naturalWidth: CGFloat = 0
    @State private var clippedWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// The truncating label reports `min(natural, proposed)`, so a ghost at its
    /// full width is all that is needed to know whether the text overflows.
    private var overflows: Bool { naturalWidth > clippedWidth + 0.5 }

    var body: some View {
        label
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(overflows ? 0 : 1)
            .background { widthReader($clippedWidth) }
            .background(alignment: .leading) {
                label.fixedSize().hidden().background { widthReader($naturalWidth) }
            }
            .overlay(alignment: .leading) {
                if overflows {
                    HStack(spacing: gap) {
                        label
                        label
                    }
                    .fixedSize()
                    .offset(x: offset)
                }
            }
            .clipped()
            .onAppear { restart() }
            .onChange(of: overflows) { _, _ in restart() }
            .onChange(of: naturalWidth) { _, _ in restart() }
    }

    private var label: some View {
        Text(verbatim: text).font(font).foregroundStyle(color)
    }

    private func widthReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { binding.wrappedValue = geo.size.width }
                .onChange(of: geo.size.width) { _, value in binding.wrappedValue = value }
        }
    }

    private func restart() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { offset = 0 }
        guard overflows, naturalWidth > 0 else { return }
        let distance = naturalWidth + gap
        withAnimation(.linear(duration: Double(distance) / speed).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}

// MARK: - Shared text shadow (readability without a panel)

private extension View {
    /// Soft wide low-alpha shadow (≈ CSS 0 2px 18px rgba(0,0,0,0.55)).
    func nowPlayingTextShadow() -> some View {
        shadow(color: .black.opacity(0.55), radius: 9, x: 0, y: 2)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Artwork (off-main decode, cached by track identity)

/// Decodes artwork off the main thread and caches the result so the 1 Hz board
/// clock does not re-decode the same bytes every tick.
@MainActor
final class NowPlayingArtworkStore {
    static let shared = NowPlayingArtworkStore()

    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let capacity = 8

    func cached(for key: String) -> CGImage? { cache[key] }

    func image(for key: String, data: Data) async -> CGImage? {
        if let hit = cache[key] { return hit }
        if let pending = inFlight[key] { return await pending.value }
        let task = Task.detached(priority: .utility) { Self.decode(data) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { store(image, for: key) }
        return image
    }

    private func store(_ image: CGImage, for key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = image
        while order.count > capacity {
            cache[order.removeFirst()] = nil
        }
    }

    /// Downsampled decode: tiles top out around 780 pt wide, so 800 px covers it.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 800
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct NowPlayingArtworkView: View {
    enum ArtworkShape {
        case rounded(CGFloat)
        case circle
    }

    let data: Data
    let cacheKey: String
    var shape: ArtworkShape = .rounded(4)

    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    clipShape.fill(.white.opacity(0.08))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(clipShape)
        }
        .task(id: cacheKey) {
            image = NowPlayingArtworkStore.shared.cached(for: cacheKey)
            if image == nil {
                image = await NowPlayingArtworkStore.shared.image(for: cacheKey, data: data)
            }
        }
    }

    private var clipShape: AnyShape {
        switch shape {
        case .rounded(let radius):
            AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .circle:
            AnyShape(Circle())
        }
    }
}

// MARK: - Previews

#if DEBUG
private extension MusicOverlayContext {
    static func nowPlayingSample(
        size: MusicOverlaySize,
        state: MonitorNowPlayingState?,
        style: NowPlayingWidgetView.Style = .poster,
        isEditing: Bool = false
    ) -> MusicOverlayContext {
        var snapshot = MonitorSnapshot()
        snapshot.timestamp = Date().timeIntervalSince1970
        snapshot.nowPlaying = state
        return MusicOverlayContext(
            snapshot: snapshot,
            size: size,
            options: style == .poster ? [:] : [NowPlayingOptions.Key.style: .string(style.rawValue)],
            isEditing: isEditing,
            reduceMotion: false,
            now: Date()
        )
    }

    static func nowPlayingFull(size: MusicOverlaySize, style: NowPlayingWidgetView.Style) -> MusicOverlayContext {
        var state = MonitorNowPlayingState(phase: .playing, title: "Weightless Horizon")
        state.artist = "Aurora Fields"
        state.album = "Slow Light"
        state.duration = 245
        state.position = 61.5
        state.positionSampledAt = Date().timeIntervalSince1970 - 10
        state.trackID = "stream:track:preview"
        return nowPlayingSample(size: size, state: state, style: style)
    }
}

#Preview("Poster · sizes") {
    VStack(spacing: 20) {
        NowPlayingWidgetView(context: .nowPlayingFull(size: .large, style: .poster))
            .frame(width: 760, height: 380)
        NowPlayingWidgetView(context: .nowPlayingFull(size: .medium, style: .poster))
            .frame(width: 560, height: 180)
    }
    .padding(32)
    .background(Design.boardWash)
}

#Preview("Vinyl / Aurora") {
    VStack(spacing: 20) {
        NowPlayingWidgetView(context: .nowPlayingFull(size: .medium, style: .vinyl))
            .frame(width: 560, height: 180)
        NowPlayingWidgetView(context: .nowPlayingFull(size: .medium, style: .aurora))
            .frame(width: 560, height: 180)
        NowPlayingWidgetView(context: .nowPlayingSample(
            size: .medium,
            state: MonitorNowPlayingState(phase: .noPlayer, title: ""),
            style: .vinyl,
            isEditing: true
        ))
        .frame(width: 560, height: 180)
    }
    .padding(32)
    .background(Design.boardWash)
}
#endif
