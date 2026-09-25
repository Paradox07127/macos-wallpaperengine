import AppKit
import LiveWallpaperCore
import Observation

/// One display on the stage. `frame` is `NSScreen.frame` (global, y-up); every other
/// rect in this contract is in window points with a top-left origin, as in SCREENS.md.
struct StageDisplay: Identifiable, Equatable {
    typealias ID = CGDirectDisplayID

    enum State: Equatable {
        case ok
        case failed(StageFailureChip)
        case paused(reasonText: String)
        case preparing(text: String)
        /// The master switch is off: the display keeps its wallpaper but draws none.
        case off(text: String)
        case empty
    }

    let id: ID
    var fingerprint: String
    var frame: CGRect
    var isBuiltin: Bool
    var name: String
    /// Type badge above the shell, e.g. `EXTERNAL · 32″ · 240 Hz`.
    var badgeText: String
    /// Mono status after the name, e.g. `主屏`.
    var statusText: String
    var cover: CGImage?
    var state: State
    /// What is playing on the screen, drawn inside the content layer. Empty only while `state` is
    /// `.empty`, where the two lines are hidden.
    var wallpaperTitle: String = ""
    /// Localized kind word for the same wallpaper, e.g. `Video`.
    var wallpaperKind: String = ""
    /// The display is in playlist mode, so previous / next exist at all.
    var showsPlaylistControls = false
    /// `WallpaperAutomationOrchestrator.advancePlaylist`'s own guards; false draws the two buttons
    /// disabled rather than hiding them.
    var canChangePlaylistEntry = false
    var canTogglePlayback = false
    /// The user's play intent, which a policy pause leaves set; false without a player.
    var intendsToPlay = false

    /// The transport's middle button offers the opposite of what the user asked for.
    var playbackGlyph: String {
        intendsToPlay ? "pause.fill" : "play.fill"
    }

    /// What VoiceOver reads after the display's name: the wallpaper, and the state unless it just runs.
    var accessibilityValue: String {
        switch state {
        case .empty:
            String(localized: "No wallpaper configured", bundle: .appLanguage)
        case .ok:
            String(
                localized: "Now playing \(wallpaperTitle)", bundle: .appLanguage,
                comment: "VoiceOver value of a display on the Edit Desk stage. Placeholder is the wallpaper's name."
            )
        case let .failed(chip):
            [wallpaperTitle, chip.text].filter { !$0.isEmpty }.joined(separator: ", ")
        case let .paused(text), let .preparing(text), let .off(text):
            [wallpaperTitle, text].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.fingerprint == rhs.fingerprint
            && lhs.frame == rhs.frame
            && lhs.isBuiltin == rhs.isBuiltin
            && lhs.name == rhs.name
            && lhs.badgeText == rhs.badgeText
            && lhs.statusText == rhs.statusText
            && lhs.cover === rhs.cover
            && lhs.state == rhs.state
            && lhs.wallpaperTitle == rhs.wallpaperTitle
            && lhs.wallpaperKind == rhs.wallpaperKind
            && lhs.showsPlaylistControls == rhs.showsPlaylistControls
            && lhs.canChangePlaylistEntry == rhs.canChangePlaylistEntry
            && lhs.canTogglePlayback == rhs.canTogglePlayback
            && lhs.intendsToPlay == rhs.intendsToPlay
    }
}

/// Names the wallpaper a display is showing. Every candidate is a value the app already holds, so
/// naming a display never reads a file it did not open or asks the network; the kind word is the
/// last resort, which is why the line is never blank.
enum StageWallpaperName {
    static func resolve(
        libraryTitle: String?, originTitle: String?, fileURL: URL?, host: String?, kind: String
    ) -> String {
        let candidates = [libraryTitle, originTitle, fileURL.map { FileManager.default.displayName(atPath: $0.path) }, host]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return kind
    }
}

/// Failure chip drawn inside a display's content layer. Values are already resolved
/// so the CALayer engine never touches SwiftUI types.
struct StageFailureChip: Equatable {
    var symbol: String
    var text: String
    var tint: CGColor

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.symbol == rhs.symbol
            && lhs.text == rhs.text
            && lhs.tint.components == rhs.tint.components
            && lhs.tint.colorSpace?.name == rhs.tint.colorSpace?.name
    }
}

struct StageCard: Identifiable, Equatable {
    typealias ID = String

    let id: ID
    var title: String
    var metaLine: String
    var thumbnail: CGImage?
    /// `ON MPG` while the card's wallpaper is running on a display; nil otherwise.
    var onBadge: String?
    var isDraggable: Bool
    /// Why the card's wallpaper cannot play here; drawn in place of `onBadge`.
    var statusBadge: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.metaLine == rhs.metaLine
            && lhs.thumbnail === rhs.thumbnail
            && lhs.onBadge == rhs.onBadge
            && lhs.isDraggable == rhs.isDraggable
            && lhs.statusBadge == rhs.statusBadge
    }

    /// Names the leftmost of the displays `ids` run on, the modal's ⌘n order, and counts the rest.
    static func onBadge(on ids: [StageDisplay.ID], among displays: [StageDisplay]) -> String? {
        let names = displays.filter { ids.contains($0.id) }.sorted { $0.frame.minX < $1.frame.minX }.map(\.name)
        guard let first = names.first else { return nil }
        return names.count == 1 ? "ON \(first)" : "ON \(first) +\(names.count - 1)"
    }
}

enum ShelfStyle: String, CaseIterable, Codable, Sendable {
    case facingIn
    case crate
    case folders
    case fan
    case focusRow

    /// The middle card is the focus and the row offset counts whole cards from it; the other
    /// styles scroll a band of cards past fixed slots.
    var isCentred: Bool {
        self == .facingIn || self == .fan || self == .focusRow
    }
}

/// One row of a context menu on the stage or of a wallpaper's "…" menu. The host builds the rows; menus only show them.
struct StageMenuItem {
    let title: String
    let isEnabled: Bool
    var isDestructive = false
    /// A submenu's rows; `action` runs only on a row without any.
    var submenu: [StageMenuItem] = []
    let action: @MainActor () -> Void
}

enum StagePlaybackAction: Equatable, Sendable {
    case previous
    case toggle
    case next
}

/// The two entry points drawn inside an empty display; dropping onto the shell is the third.
enum EmptyScreenAction: Equatable, Sendable {
    case chooseFile
    case pasteURL
}

/// What a Finder file over the stage lands on: a display applies it, the shelf only adds it to the library.
enum StageFileDropTarget: Equatable {
    case display(StageDisplay.ID)
    case shelf
}

enum StageEvent: Equatable, Sendable {
    case cardTapped(StageCard.ID)
    case cardApplyRequested(StageCard.ID)
    case displayTapped(StageDisplay.ID)
    case emptyActionTapped(StageDisplay.ID, EmptyScreenAction)
    case dropped(card: StageCard.ID, onto: StageDisplay.ID)
    /// Files dragged in from Finder, in drop order; their type is judged only after the drop.
    case filesDropped([URL], onto: StageDisplay.ID)
    /// The same, dropped on the shelf: they join the library and no display changes.
    case filesDroppedOnShelf([URL])
    case dropCancelled(card: StageCard.ID)
    case playbackTapped(StageDisplay.ID, StagePlaybackAction)
    case snapped(Int)
}

/// The stage view adopts this; `EditDeskStageModel` forwards its commands here once attached.
@MainActor
protocol EditDeskStageEngine: AnyObject {
    func setProgress(_ progress: Double, animated: Bool)
    func flyTile(display: StageDisplay.ID, to rectInWindow: CGRect) async
    /// Retargets a flight already in the air; the hero it is flying to moves with the window.
    func updateFlightDestination(display: StageDisplay.ID, to rectInWindow: CGRect)
    func setTileConcealed(display: StageDisplay.ID, _ concealed: Bool)
    func returnTile(display: StageDisplay.ID) async
    func crossfadeCover(display: StageDisplay.ID, to image: CGImage, duration: TimeInterval)
    func shake(card: StageCard.ID)
    /// A rejected Finder drop has no card to shake, so the display it landed on shakes instead.
    func shake(display: StageDisplay.ID)
    /// Esc, one level at a time; false when there is nothing to leave.
    func escape() -> Bool
}

/// Boundary between the SwiftUI chrome and the CALayer stage. SwiftUI writes the inputs,
/// the engine writes the outputs through `report(...)` / `emit(_:)`.
@MainActor @Observable
final class EditDeskStageModel {
    // MARK: SwiftUI → stage

    var displays: [StageDisplay] = []
    var shelfItems: [StageCard] = []
    var shelfStyle: ShelfStyle = .crate
    var gridTileSize: LibraryTileSize = .defaultSize
    var reduceMotion = false
    /// Increase Contrast. The stage keeps resolved CGColors, so it cannot read the setting off an
    /// appearance the way SwiftUI does; this picks the tokens' contrast tier instead.
    var increaseContrast = false
    /// True while a modal or the detail page is open: the stage ignores wheel and clicks.
    var interactionBlocked = false
    /// Only the wallpaper grid reports this; other library pages do not hand scrolls to the stage.
    var gridAtTop = false
    /// Localized "drop to replace" label drawn over a display while a card hovers it.
    var dropHintText = ""
    /// How many cards' thumbnails to keep decoded around the visible run.
    var shelfRenderBudget = StageGeometry.shelfCapacity
    /// False lets the frosted window show through: the stage stops painting its own canvas.
    var opaqueBackground = true
    /// Band at the top of the stage the display arrangement must keep clear, so the overview
    /// onboarding card does not sit on the displays (R-27). Springs to its new value.
    var arrangementTopInset: CGFloat = 0
    /// The sections of the menu a right-click or Control-click opens on a display; nil or empty opens none.
    @ObservationIgnored var displayMenu: (@MainActor (StageDisplay.ID) -> [[StageMenuItem]])?
    /// The same for a shelf card.
    @ObservationIgnored var cardMenu: (@MainActor (StageCard.ID) -> [[StageMenuItem]])?

    // MARK: Stage → SwiftUI

    /// 0…2, tracks the gesture; `snappedIndex` only moves once the snap animation lands.
    private(set) var progress: Double = 0
    /// Past the halfway point of the first leg the cards are readable, so the chrome that belongs
    /// to the shelf comes with them.
    var showsShelf: Bool {
        progress > 0.5
    }

    private(set) var snappedIndex = 0
    private(set) var hoveredCard: StageCard.ID?
    /// Where that card is drawn, in stage coordinates. The name rides above it, so the chrome has
    /// to follow the card rather than sit at a fixed spot in the row.
    private(set) var hoveredCardRect: CGRect?
    private(set) var hoveredDisplay: StageDisplay.ID?
    private(set) var dropTarget: StageDisplay.ID?
    /// A Finder file is over the shelf band, where a drop only adds it to the library.
    private(set) var shelfDropTargeted = false
    /// Slice of `shelfItems` the stage has layers for; the owner loads thumbnails for these.
    private(set) var visibleShelfRange = 0 ..< 0
    /// The grid's own slice while the shelf flies to p = 2. Disjoint from `visibleShelfRange` once
    /// the row is scrolled, so the owner needs both rather than the span between them.
    private(set) var visibleGridRange = 0 ..< 0
    /// The stage view's own bounds. SwiftUI's geometry reader sees the safe-area-reduced height,
    /// which put the chrome 28pt off the shelf it is supposed to ride on.
    private(set) var stageSize = StageGeometry.designWindow

    /// Single consumer: `HomePage` owns the read loop; a second `for await` would split the events.
    let events: AsyncStream<StageEvent>
    private let eventContinuation: AsyncStream<StageEvent>.Continuation

    /// Set by the stage view on attach. Without one, commands land on the outputs directly
    /// so previews and tests see the rest state they asked for.
    @ObservationIgnored weak var engine: (any EditDeskStageEngine)?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: StageEvent.self, bufferingPolicy: .unbounded)
        events = stream
        eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: Commands

    func setProgress(_ progress: Double, animated: Bool) {
        let clamped = StageGeometry.clampProgress(progress)
        if let engine {
            engine.setProgress(clamped, animated: animated)
            return
        }
        report(progress: clamped)
        if clamped == clamped.rounded() {
            let index = Int(clamped)
            report(snappedIndex: index)
            emit(.snapped(index))
        }
    }

    func flyTile(display: StageDisplay.ID, to rectInWindow: CGRect) async {
        await engine?.flyTile(display: display, to: rectInWindow)
    }

    func updateFlightDestination(display: StageDisplay.ID, to rectInWindow: CGRect) {
        engine?.updateFlightDestination(display: display, to: rectInWindow)
    }

    func returnTile(display: StageDisplay.ID) async {
        await engine?.returnTile(display: display)
    }

    func setTileConcealed(display: StageDisplay.ID, _ concealed: Bool) {
        engine?.setTileConcealed(display: display, concealed)
    }

    func crossfadeCover(display: StageDisplay.ID, to image: CGImage, duration: TimeInterval) {
        engine?.crossfadeCover(display: display, to: image, duration: duration)
    }

    func shake(card: StageCard.ID) {
        engine?.shake(card: card)
    }

    func shake(display: StageDisplay.ID) {
        engine?.shake(display: display)
    }

    func escape() -> Bool {
        engine?.escape() ?? false
    }

    // MARK: Engine → model (unchanged values do not notify observers; the engine reports every frame)

    func report(progress: Double) {
        if self.progress != progress {
            self.progress = progress
        }
    }

    func report(snappedIndex: Int) {
        if self.snappedIndex != snappedIndex {
            self.snappedIndex = snappedIndex
        }
    }

    func report(hoveredCardRect rect: CGRect?) {
        if hoveredCardRect != rect {
            hoveredCardRect = rect
        }
    }

    func report(hoveredCard: StageCard.ID?) {
        if self.hoveredCard != hoveredCard {
            self.hoveredCard = hoveredCard
        }
    }

    func report(hoveredDisplay: StageDisplay.ID?) {
        if self.hoveredDisplay != hoveredDisplay {
            self.hoveredDisplay = hoveredDisplay
        }
    }

    func report(stageSize: CGSize) {
        if self.stageSize != stageSize, stageSize.width > 0, stageSize.height > 0 {
            self.stageSize = stageSize
        }
    }

    func report(visibleShelfRange: Range<Int>) {
        if self.visibleShelfRange != visibleShelfRange {
            self.visibleShelfRange = visibleShelfRange
        }
    }

    func report(visibleGridRange: Range<Int>) {
        if self.visibleGridRange != visibleGridRange {
            self.visibleGridRange = visibleGridRange
        }
    }

    func report(dropTarget: StageDisplay.ID?) {
        if self.dropTarget != dropTarget {
            self.dropTarget = dropTarget
        }
    }

    func report(shelfDropTargeted: Bool) {
        if self.shelfDropTargeted != shelfDropTargeted {
            self.shelfDropTargeted = shelfDropTargeted
        }
    }

    func emit(_ event: StageEvent) {
        eventContinuation.yield(event)
    }

    // MARK: Thumbnails

    /// Cards past each end of the drawn run that keep, or load ahead, their thumbnails.
    static let thumbnailLead = 4

    /// Clears thumbnails outside the kept band (a card holds its image strongly), fills bare cards inside it from `cached`, and returns those still bare, ascending.
    func refreshShelfThumbnails(cached: (Int) -> CGImage?) -> [Int] {
        let kept = keptThumbnailIndices
        var missing: [Int] = []
        for index in shelfItems.indices {
            if !kept.contains(index) {
                if shelfItems[index].thumbnail != nil {
                    shelfItems[index].thumbnail = nil
                }
            } else if shelfItems[index].thumbnail == nil {
                if let image = cached(index) {
                    shelfItems[index].thumbnail = image
                } else {
                    missing.append(index)
                }
            }
        }
        return missing
    }

    /// Hands a finished decode to its card unless the card has left the kept band meanwhile; the image stays in the cache for the next refresh.
    func landThumbnail(_ image: CGImage, for id: StageCard.ID) {
        guard let index = shelfItems.firstIndex(where: { $0.id == id }), keptThumbnailIndices.contains(index) else { return }
        shelfItems[index].thumbnail = image
    }

    private var keptThumbnailIndices: Set<Int> {
        var kept = Set(visibleGridRange.clamped(to: shelfItems.indices))
        if !visibleShelfRange.isEmpty {
            let lead = Self.thumbnailLead
            kept.formUnion((visibleShelfRange.lowerBound - lead ..< visibleShelfRange.upperBound + lead).clamped(to: shelfItems.indices))
        }
        return kept
    }
}
