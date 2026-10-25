import LiveWallpaperCore
import SwiftUI

struct ShuffleDeck: View {
    struct Card: Identifiable, Equatable {
        let id: String
        let title: String
        let image: CGImage?
    }

    let current: Card?
    /// Oldest first; the newest few lie under `current`.
    let played: [Card]
    /// Face-down cards left in the deck; only sets how thick the deck looks.
    let remaining: Int
    /// The caller adds 1 per reshuffle; every change plays the shuffle once.
    let reshuffles: Int
    let onDraw: () -> Void
    /// nil disables Previous Wallpaper.
    let onRewind: (() -> Void)?
    let onReshuffle: () -> Void

    /// The face-up card's thumbnail in points, before any scaling by the caller.
    static let thumbnailSize = CGSize(width: Layout.cardSize.width - 2 * Layout.facePadding, height: Layout.thumbnailHeight)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cards: [Placed]
    /// Non-nil while a draw, rewind or shuffle is still moving cards.
    @State private var timeline: Task<Void, Never>?

    init(
        current: Card?,
        played: [Card],
        remaining: Int,
        reshuffles: Int,
        onDraw: @escaping () -> Void,
        onRewind: (() -> Void)?,
        onReshuffle: @escaping () -> Void
    ) {
        self.current = current
        self.played = played
        self.remaining = remaining
        self.reshuffles = reshuffles
        self.onDraw = onDraw
        self.onRewind = onRewind
        self.onReshuffle = onReshuffle
        _cards = State(initialValue: Self.restLayout(current: current, played: played, remaining: remaining))
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            table
            controls
        }
        .onChange(of: changeKey) { old, new in
            apply(from: old, to: new)
        }
        .onDisappear {
            timeline?.cancel()
            timeline = nil
        }
    }

    private var table: some View {
        let live = liveCards
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(DesignTokens.EditDesk.Colors.strokeDashedCard, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: Layout.deckCardSize.width, height: Layout.deckCardSize.height)
                .position(Layout.deckCenter)
                .accessibilityHidden(true)
            ForEach(cards) { placed in
                let card = placed.card.map { live[$0.id] ?? $0 }
                PlacedCard(card: card, pose: placed.pose)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: card?.title ?? ""))
                    .accessibilityHidden(placed.role != .current)
                    .zIndex(placed.z)
                    .transition(.opacity)
                    .animation(placed.motion, value: placed.pose)
            }
            DeckButton(action: onDraw)
                .frame(width: Layout.deckCardSize.width, height: Layout.deckCardSize.height)
                .position(Layout.deckCenter)
                .zIndex(Layout.Z.hitArea)
        }
        .frame(width: Layout.tableSize.width, height: Layout.tableSize.height)
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button {
                onRewind?()
            } label: {
                Label("Previous Wallpaper", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(onRewind == nil)
            Button(action: onDraw) {
                Label("Next Wallpaper", systemImage: "rectangle.on.rectangle.angled")
            }
            .buttonStyle(.borderedProminent)
            Button(action: onReshuffle) {
                Label("Reshuffle", systemImage: "shuffle")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    /// Fresh copies of the cards on the table, so a thumbnail that arrives later shows up.
    private var liveCards: [String: Card] {
        var cards = Dictionary(played.suffix(Layout.visiblePile).map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        if let current {
            cards[current.id] = current
        }
        return cards
    }

    private var changeKey: ChangeKey {
        ChangeKey(current: current?.id, played: played.map(\.id), remaining: remaining, reshuffles: reshuffles)
    }

    // MARK: - Transitions

    private func apply(from old: ChangeKey, to new: ChangeKey) {
        let target = Self.restLayout(current: current, played: played, remaining: remaining)
        if let running = timeline {
            running.cancel()
            timeline = nil
            snap(target)
        } else if reduceMotion {
            withAnimation(DesignTokens.Motion.reducedMotionFade) { cards = target }
        } else if old.reshuffles != new.reshuffles {
            shuffle(into: target)
        } else if let previousID = old.current, let drawn = current, new.played == old.played + [previousID] {
            draw(drawn, replacing: previousID, into: target)
        } else if let risen = current, risen.id == old.played.last, new.played == Array(old.played.dropLast()) {
            rewind(to: risen, sending: old.current, into: target)
        } else {
            withAnimation(DesignTokens.Motion.stateChange) { cards = target }
        }
    }

    private func draw(_ drawn: Card, replacing previousID: String, into target: [Placed]) {
        let motion = DesignTokens.ShuffleDeck.self
        let flying = Placed(role: .current, card: drawn, pose: .deck(depth: 0), z: Layout.Z.flying)
        let start = cards.filter { $0.role != .deck } + target.filter { $0.role == .deck } + [flying]
        snap(start)
        run {
            var lifted = flying
            lifted.pose = Pose.deck(depth: 0).lifted
            lifted.motion = motion.curve(motion.liftDuration)
            cards = Array(start.dropLast()) + [lifted]
            try await Self.pause(motion.liftDuration)
            let travel = target.map { placed in
                var placed = placed
                placed.motion = motion.curve(motion.travelDuration)
                // Keeps the replaced card's identity, so it slides onto the pile instead of fading.
                if placed.id == Placed.id(.played, previousID) {
                    placed.id = Placed.id(.current, previousID)
                }
                if placed.role == .current {
                    placed.z = Layout.Z.flying
                }
                return placed
            }
            withAnimation(DesignTokens.Motion.stateChange) { cards = travel }
            try await Self.pause(motion.travelDuration)
            snap(target)
        }
    }

    private func rewind(to risen: Card, sending previousID: String?, into target: [Placed]) {
        let motion = DesignTokens.ShuffleDeck.self
        var travel = target.map { placed in
            var placed = placed
            placed.motion = motion.curve(motion.travelDuration)
            if placed.role == .current {
                placed.id = Placed.id(.played, risen.id)
            }
            return placed
        }
        if let previousID, var returning = cards.first(where: { $0.id == Placed.id(.current, previousID) }) {
            returning.role = .deck
            returning.pose = .deck(depth: 0)
            returning.z = Layout.Z.flying
            returning.motion = motion.curve(motion.travelDuration)
            travel.append(returning)
        }
        withAnimation(DesignTokens.Motion.stateChange) { cards = travel }
        run {
            try await Self.pause(motion.travelDuration)
            snap(target)
        }
    }

    private func shuffle(into target: [Placed]) {
        let motion = DesignTokens.ShuffleDeck.self
        let deck = target.filter { $0.role == .deck }
        let rest = target.filter { $0.role != .deck }
        let kept = Set(target.map(\.id))
        let gathered = cards.filter { $0.role == .played && !kept.contains($0.id) }.enumerated().map { index, placed in
            var placed = placed
            placed.pose = .deck(depth: 0)
            placed.z = Layout.Z.gathered + Double(index)
            placed.motion = motion.curve(motion.gatherDuration)
            return placed
        }
        withAnimation(DesignTokens.Motion.stateChange) { cards = deck + rest + gathered }
        run {
            if !gathered.isEmpty {
                try await Self.pause(motion.gatherDuration)
            }
            cards = rest + Self.fanned(deck, split: true)
            // Each card holds the split two stagger steps past its own split before merging.
            try await Self.pause(motion.splitDuration + 2 * motion.stagger)
            cards = rest + Self.fanned(deck, split: false)
            try await Self.pause(Double(deck.count) * motion.stagger + motion.splitDuration)
            cards = target.map { placed in
                var placed = placed
                placed.motion = motion.curve(motion.settleDuration)
                return placed
            }
            try await Self.pause(motion.settleDuration)
            snap(target)
        }
    }

    /// `deck` is in depth order, top first, as `restLayout` builds it.
    private static func fanned(_ deck: [Placed], split: Bool) -> [Placed] {
        let motion = DesignTokens.ShuffleDeck.self
        return deck.enumerated().map { depth, placed in
            var placed = placed
            let index = deck.count - 1 - depth
            var pose = Pose.deck(depth: depth)
            if split {
                let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                pose.center.x += side * Layout.splitReach.width
                pose.center.y -= Layout.splitReach.height
                pose.tilt = Double(side) * Layout.splitTilt
            } else {
                // The design's fixed scatter, so the merged halves don't land square.
                pose.center.x += CGFloat((index * 37) % 9 - 4)
                pose.tilt = Double((index * 53) % 7 - 3)
            }
            placed.pose = pose
            placed.motion = motion.curve(motion.splitDuration).delay(Double(index) * motion.stagger)
            return placed
        }
    }

    private func snap(_ layout: [Placed]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { cards = layout }
    }

    private func run(_ steps: @escaping @MainActor () async throws -> Void) {
        timeline = Task { @MainActor in
            do { try await steps() } catch { return }
            timeline = nil
        }
    }

    private static func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func restLayout(current: Card?, played: [Card], remaining: Int) -> [Placed] {
        let layers = max(0, min(remaining, Layout.maxLayers))
        var layout = (0 ..< layers).map { depth in
            Placed(id: "deck-\(depth)", role: .deck, card: nil, pose: .deck(depth: depth), z: Double(Layout.maxLayers - depth))
        }
        for (index, card) in played.suffix(Layout.visiblePile).enumerated() {
            layout.append(Placed(role: .played, card: card, pose: .pile(card.id), z: Layout.Z.pile + Double(index)))
        }
        if let current {
            layout.append(Placed(role: .current, card: current, pose: .playing, z: Layout.Z.playing))
        }
        return layout
    }
}

// MARK: - Model

private struct ChangeKey: Equatable {
    var current: String?
    var played: [String]
    var remaining: Int
    var reshuffles: Int
}

private struct Placed: Identifiable {
    enum Role: String {
        case deck
        case played
        case current
    }

    /// Carries the role, so a card changing role fades unless a transition keeps its old id on purpose.
    var id: String
    var role: Role
    /// nil = an anonymous card back in the deck.
    var card: ShuffleDeck.Card?
    var pose: Pose
    var z: Double
    /// nil = the pose snaps.
    var motion: Animation?

    init(id: String? = nil, role: Role, card: ShuffleDeck.Card?, pose: Pose, z: Double) {
        self.id = id ?? Self.id(role, card?.id ?? "")
        self.role = role
        self.card = card
        self.pose = pose
        self.z = z
    }

    static func id(_ role: Role, _ cardID: String) -> String {
        "\(role.rawValue)-\(cardID)"
    }
}

private struct Pose: Equatable {
    enum Elevation {
        case resting
        case playing
        case lifted
    }

    /// In table coordinates.
    var center: CGPoint
    /// Degrees.
    var tilt: Double = 0
    /// Degrees about the y axis; 0 = face up, 180 = face down.
    var flip: Double = 0
    var scale: CGFloat = 1
    var elevation: Elevation = .resting

    static let playing = Pose(center: Layout.playingCenter, elevation: .playing)

    static func deck(depth: Int) -> Pose {
        let step = CGFloat(depth) * Layout.layerStep
        return Pose(
            center: CGPoint(x: Layout.deckCenter.x + step, y: Layout.deckCenter.y + step),
            flip: 180,
            scale: Layout.deckScale
        )
    }

    static func pile(_ cardID: String) -> Pose {
        // FNV-1a over the scalars: `hashValue` is reseeded every launch, and the pile must not reshuffle with it.
        let hash = cardID.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        let reach = Layout.pileReach
        let spread = Layout.pileTiltSpread
        let magnitude = Layout.pileTiltMinimum + Double((hash >> 16) % (spread + 1)) / 10
        return Pose(
            center: CGPoint(
                x: Layout.playingCenter.x + CGFloat(Int(hash % (2 * reach + 1)) - Int(reach)),
                y: Layout.playingCenter.y + CGFloat(Int((hash >> 8) % (2 * reach + 1)) - Int(reach))
            ),
            tilt: (hash >> 28) & 1 == 0 ? magnitude : -magnitude
        )
    }

    var lifted: Pose {
        var pose = self
        pose.center.y -= Layout.liftRise
        pose.scale += Layout.liftGrowth
        pose.elevation = .lifted
        return pose
    }
}

/// Geometry from the deck design; the deck shows cards at `deckScale` of the playing card.
private enum Layout {
    static let cardSize = CGSize(width: 312, height: 212)
    static let deckScale: CGFloat = 0.62
    static let deckCardSize = CGSize(width: cardSize.width * deckScale, height: cardSize.height * deckScale)
    /// Leaves room for the split halves, the lift and the pile's tilted corners.
    static let tableSize = CGSize(width: 630, height: 320)
    static let deckCenter = CGPoint(x: 155, y: 140)
    static let playingCenter = CGPoint(x: 445, y: 160)
    /// Each card further down the deck sits this far right and down.
    static let layerStep: CGFloat = 2
    static let maxLayers = 8
    static let visiblePile = 4
    /// Pile offset bound in pt, ±.
    static let pileReach: UInt32 = 10
    /// Pile tilt in degrees runs from the minimum up by `pileTiltSpread` tenths, either way; the floor keeps
    /// the card under the playing one showing a corner.
    static let pileTiltMinimum: Double = 3.5
    static let pileTiltSpread: UInt32 = 35
    static let liftRise: CGFloat = 30
    static let liftGrowth: CGFloat = 0.04
    static let splitReach = CGSize(width: 55, height: 35)
    static let splitTilt: Double = 7
    static let facePadding: CGFloat = 6
    static let titleGap: CGFloat = 7
    static let thumbnailHeight: CGFloat = 168
    static let stripeWidth: CGFloat = 6
    static let emblemDiameter: CGFloat = 62

    enum Z {
        static let gathered: Double = 10
        static let pile: Double = 20
        static let playing: Double = 40
        static let flying: Double = 100
        static let hitArea: Double = 200
    }
}

// MARK: - Card views

private struct PlacedCard: View {
    let card: ShuffleDeck.Card?
    let pose: Pose

    var body: some View {
        let shadow = switch pose.elevation {
        case .resting: DesignTokens.EditDesk.Shadow.shelfCard
        case .playing: DesignTokens.EditDesk.Shadow.shelfCardHover
        case .lifted: DesignTokens.EditDesk.Shadow.modal
        }
        FlipCard(angle: pose.flip, front: face, back: CardBack())
            .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
            .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
            .scaleEffect(pose.scale)
            .rotationEffect(.degrees(pose.tilt))
            .position(pose.center)
    }

    @ViewBuilder private var face: some View {
        if let card {
            CardFace(card: card)
        } else {
            CardBack()
        }
    }
}

/// Swaps faces when the animated angle passes 90°; a plain `rotation3DEffect` would show the front mirrored.
private struct FlipCard<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if cos(angle * .pi / 180) < 0 {
                back.scaleEffect(x: -1)
            } else {
                front
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0))
    }
}

private struct CardFace: View {
    let card: ShuffleDeck.Card

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
        VStack(alignment: .leading, spacing: Layout.titleGap) {
            DesignTokens.Colors.surfaceSunken
                .overlay {
                    if let image = card.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Layout.thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard, style: .continuous))
            Text(verbatim: card.title)
                .font(DesignTokens.EditDesk.Typography.workshopCardTitle)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, Layout.facePadding)
        }
        .padding(Layout.facePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shape.fill(DesignTokens.Colors.surfaceRaised))
        .overlay(shape.strokeBorder(DesignTokens.EditDesk.Colors.strokeBadge, lineWidth: 1))
    }
}

private struct CardBack: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
        let stripe = DesignTokens.Colors.textPrimary.opacity(0.04)
        ZStack {
            shape.fill(DesignTokens.Colors.surfaceSunken)
            Canvas { context, size in
                let span = size.width + size.height
                context.translateBy(x: size.width / 2, y: size.height / 2)
                context.rotate(by: .degrees(45))
                var x = -span
                while x < span {
                    context.fill(Path(CGRect(x: x, y: -span, width: Layout.stripeWidth, height: span * 2)), with: .color(stripe))
                    x += Layout.stripeWidth * 2
                }
            }
            .clipShape(shape)
            Image(systemName: "shuffle")
                .font(.system(size: 22))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: Layout.emblemDiameter, height: Layout.emblemDiameter)
                .background(Circle().fill(DesignTokens.EditDesk.Colors.console))
                .overlay(Circle().strokeBorder(DesignTokens.EditDesk.Colors.strokeBadge, lineWidth: 1))
        }
        .overlay(shape.strokeBorder(DesignTokens.EditDesk.Colors.strokePanel, lineWidth: 1))
    }
}

/// The deck's click target, laid over the deck so the moving cards keep their own identity.
private struct DeckButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(DeckPressStyle(hovered: hovered))
        .onHover { hovered = $0 }
        .accessibilityLabel(Text("Next Wallpaper"))
    }
}

private struct DeckPressStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let opacity = configuration.isPressed
            ? DesignTokens.Opacity.dragFill
            : hovered ? DesignTokens.Opacity.hoverFill : 0
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard, style: .continuous)
                    .fill(DesignTokens.Colors.textPrimary.opacity(opacity))
            )
            .animation(DesignTokens.Motion.feedback, value: opacity)
    }
}
