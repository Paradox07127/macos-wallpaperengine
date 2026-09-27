#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// SCREENS S8's Workshop card at the widths a 1040 and a 1280 window give it. Each check compares two renders of the
/// same card drawn the same way, so light or dark, 1x or 2x and Reduce Transparency change both sides alike.
@MainActor
@Suite("Edit Desk browse card layout", .serialized)
struct BrowseCardEditDeskLayoutTests {
    /// What differs between a desk and the hosted CI runner (light, Reduce Transparency on, possibly 1x), set explicitly.
    struct Drawing: CustomTestStringConvertible, Sendable {
        let dark: Bool
        let scale: CGFloat
        let reduceTransparency: Bool

        var testDescription: String {
            "\(dark ? "dark" : "light") \(Int(scale))x\(reduceTransparency ? " reduce-transparency" : "")"
        }

        static let all: [Drawing] = [false, true].flatMap { dark in
            [CGFloat(1), 2].flatMap { scale in
                [false, true].map { Drawing(dark: dark, scale: scale, reduceTransparency: $0) }
            }
        }
    }

    private static let languages: [AppLanguagePreference] = [.simplifiedChinese, .english, .japanese, .spanish]

    /// A 1040 and a 1280 window, each with and without a legacy scroller taking its width out of the row.
    private static var cardWidths: [CGFloat] {
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        return [CGFloat(1040), 1280].flatMap { window in
            [CGFloat(0), scroller].map { gutter in
                DesignTokens.LibraryGrid.resolvedColumnWidth(
                    for: .medium, aspect: .square,
                    fitting: window - 2 * DesignTokens.Settings.formHorizontalMargin - gutter,
                    columnWidth: DesignTokens.LibraryGrid.workshopBrowseColumnWidth
                )
            }
        }
    }

    private static func item(subscribers: Int) -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: 3_100_000_001, rawTitle: "Azur Lane · Summer Night", shortDescription: "", creatorID: nil,
            previewImageURL: nil, fileSizeBytes: 1_234_000_000, timeUpdated: nil, subscriptionCount: subscribers,
            rating: .score(0.96, votesUp: 96, votesDown: 4), tags: ["Scene", "3840 x 2160"],
            visibility: .public, isBanned: false,
            steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=3100000001")!
        )
    }

    private static func nowPlaying(_ names: [String]) -> NowPlayingBadge? {
        let displays = names.enumerated().map { index, name in
            StageDisplay(
                id: CGDirectDisplayID(index + 1), fingerprint: name,
                frame: CGRect(x: CGFloat(index) * 1920, y: 0, width: 1920, height: 1080), isBuiltin: false,
                name: name, badgeText: "", statusText: "", cover: nil, state: .ok
            )
        }
        return NowPlayingBadge(on: displays.map(\.id), among: displays)
    }

    private static func card(
        _ item: WorkshopQueryItem, inUse: NowPlayingBadge? = nil, hasUpdate: Bool = false, isInLibrary: Bool = true,
        showsResolution: Bool = true
    ) -> BrowseCard {
        BrowseCard(
            item: item, isInLibrary: isInLibrary, hasUpdate: hasUpdate, inUseBadge: inUse,
            cardPreferences: GalleryCardPreferences(showsResolution: showsResolution), reduceMotion: true, presentation: .editDesk
        )
    }

    /// Drawn at `drawing`'s scale whatever the screen's, under its appearance and transparency setting, and
    /// synchronously, so the caller's app-language override is the one it reads.
    private static func render(_ view: some View, width: CGFloat, height: CGFloat, in drawing: Drawing) throws -> ProbeImage {
        let content = AppLanguageScope(defaults: .standard) {
            view.frame(width: width, height: height)
        }
        .environment(\.colorScheme, drawing.dark ? .dark : .light)
        .environment(\._accessibilityReduceTransparency, drawing.reduceTransparency)
        let renderer = ImageRenderer(content: content)
        renderer.scale = drawing.scale
        var image: CGImage?
        NSAppearance(named: drawing.dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        let cgImage = try #require(image, "\(drawing.testDescription): nothing rendered")
        return ProbeImage(cgImage: cgImage, viewWidth: CGFloat(cgImage.width) / drawing.scale)
    }

    private static func idealSize(_ view: some View) -> CGSize {
        NSHostingView(rootView: view.fixedSize()).fittingSize
    }

    /// Share of the pixels in a `size` region (points) that differ by more than a few levels between `lhs` at
    /// `lhsOrigin` and `rhs` at `rhsOrigin`, taking the best of up to `verticalSlack` points either way.
    private static func differingShare(
        _ lhs: ProbeImage, at lhsOrigin: CGPoint, _ rhs: ProbeImage, at rhsOrigin: CGPoint, size: CGSize, verticalSlack: CGFloat = 0
    ) -> Double {
        let scale = lhs.scale
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        let lx = Int((lhsOrigin.x * scale).rounded()), ly = Int((lhsOrigin.y * scale).rounded())
        let rx = Int((rhsOrigin.x * scale).rounded()), ry = Int((rhsOrigin.y * scale).rounded())
        let slack = Int((verticalSlack * scale).rounded())
        return (-slack ... slack).map { dy in
            var differing = 0
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let a = lhs.rgb(px: lx + x, ly + y + dy), b = rhs.rgb(px: rx + x, ry + y)
                    if abs(a.r - b.r) > 8 || abs(a.g - b.g) > 8 || abs(a.b - b.b) > 8 {
                        differing += 1
                    }
                }
            }
            return Double(differing) / Double(max(1, width * height))
        }.min() ?? 1
    }

    // MARK: - Subscriber count

    /// The card's words for `count`: the plain key below 1,000, the compact one above.
    private static func subscribersText(_ count: Int) -> String {
        let locale = AppLanguagePreference.current.locale
        return count < WorkshopCountFormatter.compactFloor
            ? String(localized: "\(count) subscribers", bundle: .appLanguage, locale: locale)
            : String(localized: "\(WorkshopCountFormatter.compact(count)) subscribers", bundle: .appLanguage, locale: locale)
    }

    private static func metaTextSize(_ text: String) -> CGSize {
        idealSize(Text(verbatim: text).font(DesignTokens.EditDesk.Typography.badgeMono).lineLimit(1))
    }

    /// Where the band's second row starts in a `side`-point card, a point above the text so its descenders are in.
    private static func statsRowOrigin(side: CGFloat, textHeight: CGFloat) -> CGPoint {
        let inset = DesignTokens.EditDesk.Spacing.workshopCardBandInset
        return CGPoint(x: inset, y: side - inset - textHeight - 1)
    }

    /// Pixels bright enough to be the band's dimmed white text rather than the gradient behind it.
    private static func inkShare(_ image: ProbeImage, at origin: CGPoint, size: CGSize) -> Double {
        let x0 = Int((origin.x * image.scale).rounded()), y0 = Int((origin.y * image.scale).rounded())
        let width = Int((size.width * image.scale).rounded()), height = Int((size.height * image.scale).rounded())
        var ink = 0
        for y in y0 ..< y0 + height {
            for x in x0 ..< x0 + width {
                let pixel = image.rgb(px: x, y)
                if max(pixel.r, pixel.g, pixel.b) >= 150 {
                    ink += 1
                }
            }
        }
        return Double(ink) / Double(max(1, width * height))
    }

    /// A card 100pt wider draws the count at the same place and never cuts it; adding whole points keeps the width's
    /// fraction, so both renders land on the pixel grid alike.
    @Test("The subscriber count is drawn in full at 1040 and 1280, in zh-Hans, en, ja and es", arguments: Drawing.all)
    func subscriberCountIsNotCutOff(in drawing: Drawing) throws {
        for language in Self.languages {
            try AppLanguageOverride.with(language) {
                for count in [6700, 123_400] {
                    let phrase = Self.subscribersText(count)
                    let text = Self.metaTextSize(phrase)
                    let region = CGSize(width: text.width, height: text.height + 2)
                    let item = Self.item(subscribers: count)
                    for width in Self.cardWidths {
                        let card = try Self.render(Self.card(item), width: width, height: width, in: drawing)
                        let roomy = try Self.render(Self.card(item), width: width + 100, height: width + 100, in: drawing)
                        let roomyOrigin = Self.statsRowOrigin(side: width + 100, textHeight: text.height)
                        let label = "\(drawing.testDescription) \(language.rawValue) \(String(format: "%.1f", width))pt \"\(phrase)\""
                        #expect(Self.inkShare(roomy, at: roomyOrigin, size: region) > 0.02, "\(label): the roomy card draws no count to compare with")
                        let share = Self.differingShare(
                            card, at: Self.statsRowOrigin(side: width, textHeight: text.height), roomy, at: roomyOrigin, size: region
                        )
                        #expect(share <= 0.002, "\(label): the count is not drawn whole (\(String(format: "%.3f", share)) of its pixels differ)")
                    }
                }
            }
        }
    }

    @Test("Control: a count cut short differs from the same card drawn roomier", arguments: Drawing.all)
    func truncationIsNoticed(in drawing: Drawing) throws {
        try AppLanguageOverride.with(.japanese) {
            let phrase = Self.subscribersText(123_400)
            let text = Self.metaTextSize(phrase)
            // 130pt of band for a count that needs more.
            let side: CGFloat = 150.6
            let region = CGSize(width: side - 2 * DesignTokens.EditDesk.Spacing.workshopCardBandInset, height: text.height + 2)
            let item = Self.item(subscribers: 123_400)
            let card = try Self.render(Self.card(item), width: side, height: side, in: drawing)
            let roomy = try Self.render(Self.card(item), width: side + 100, height: side + 100, in: drawing)
            let share = Self.differingShare(
                card, at: Self.statsRowOrigin(side: side, textHeight: text.height),
                roomy, at: Self.statsRowOrigin(side: side + 100, textHeight: text.height), size: region
            )
            // Only the last glyphs change, so the share is small; it still has to clear the 0.002 a whole count may differ by.
            #expect(share > 0.01, "\(drawing.testDescription): a count cut to 130pt reads as whole (\(share))")
        }
    }

    // MARK: - Top badges

    /// Needing an update must leave the in-use capsule, and the 2pt beside it, exactly as they are with nothing else on
    /// the row: a badge running into it, or the capsule giving up width, changes those pixels. The row centres its
    /// badges, so the capsule may sit a pixel lower when the other end holds a taller one.
    @Test("In use and needing an update, the capsule is drawn as when alone and the update still shows", arguments: Drawing.all)
    func inUseAndUpdateBadgesDoNotOverlap(in drawing: Drawing) throws {
        for language in Self.languages {
            try AppLanguageOverride.with(language) {
                let update = String(localized: "Update available", bundle: .appLanguage)
                let badge = try #require(Self.nowPlaying(["MPG321CX", "PD3205U"]))
                let capsule = Self.idealSize(NowPlayingCapsule(badge: badge, animates: false))
                let item = Self.item(subscribers: 123_400)
                let inset = DesignTokens.Spacing.sm
                for width in Self.cardWidths {
                    let crowded = Self.card(item, inUse: badge, hasUpdate: true)
                    let alone = Self.card(item, inUse: badge, isInLibrary: false)
                    let crowdedImage = try Self.render(crowded, width: width, height: width, in: drawing)
                    let aloneImage = try Self.render(alone, width: width, height: width, in: drawing)
                    let label = "\(drawing.testDescription) \(language.rawValue) \(String(format: "%.1f", width))pt"
                    let capsuleShare = Self.differingShare(
                        crowdedImage, at: CGPoint(x: inset, y: inset), aloneImage, at: CGPoint(x: inset, y: inset),
                        size: CGSize(width: capsule.width + 2, height: capsule.height), verticalSlack: 1
                    )
                    #expect(capsuleShare <= 0.002, "\(label): the capsule is covered or squeezed (\(String(format: "%.3f", capsuleShare)) of it differs)")
                    let trailing = CGPoint(x: width / 2, y: inset)
                    let trailingShare = Self.differingShare(
                        crowdedImage, at: trailing, aloneImage, at: trailing, size: CGSize(width: width / 2 - inset, height: capsule.height)
                    )
                    #expect(trailingShare > 0.02, "\(label): the update badge is gone")
                    #expect(crowded.accessibilityLabelText.contains(update), "\(label): VoiceOver no longer hears the update")
                }
            }
        }
    }

    @Test("Control: a badge over the capsule, or a squeezed capsule, differs from the capsule alone", arguments: Drawing.all)
    func overlapAndSqueezeAreNoticed(in drawing: Drawing) throws {
        try AppLanguageOverride.with(.spanish) {
            let badge = try #require(Self.nowPlaying(["MPG321CX", "PD3205U"]))
            let capsule = Self.idealSize(NowPlayingCapsule(badge: badge, animates: false))
            let inset = DesignTokens.Spacing.sm
            @MainActor func row(@ViewBuilder _ content: () -> some View) throws -> ProbeImage {
                try Self.render(
                    ZStack(alignment: .topLeading) {
                        Color.gray
                        content().padding(inset)
                    }
                    .thumbnailBadgeSurface(.opaque),
                    width: 190, height: 190, in: drawing
                )
            }
            let alone = try row { NowPlayingCapsule(badge: badge, animates: false) }
            let covered = try row {
                ZStack(alignment: .topLeading) {
                    NowPlayingCapsule(badge: badge, animates: false)
                    ThumbnailBadge("Needs Update", systemImage: "arrow.down.circle", tint: DesignTokens.Colors.Status.warning, opacity: 0.9)
                        .padding(.leading, 40)
                }
            }
            let squeezed = try row { NowPlayingCapsule(badge: badge, animates: false).frame(width: capsule.width - 30) }
            let size = CGSize(width: capsule.width + 2, height: capsule.height)
            let origin = CGPoint(x: inset, y: inset)
            let coveredShare = Self.differingShare(covered, at: origin, alone, at: origin, size: size, verticalSlack: 1)
            let squeezedShare = Self.differingShare(squeezed, at: origin, alone, at: origin, size: size, verticalSlack: 1)
            #expect(coveredShare > 0.02, "\(drawing.testDescription): a badge drawn 40pt in reads as clear of the capsule")
            #expect(squeezedShare > 0.02, "\(drawing.testDescription): a capsule 30pt short reads as whole")
        }
    }

    /// No 1040 or 1280 width fits the capsule, the resolution and the update's caption together, so the resolution is the
    /// one gone: the row matches the same card with the resolution switched off, whether the caption or only its icon shows.
    @Test("In use and needing an update, the resolution gives way before the update's caption", arguments: Drawing.all)
    func resolutionGivesWayBeforeUpdateCaption(in drawing: Drawing) throws {
        for language in Self.languages {
            try AppLanguageOverride.with(language) {
                let badge = try #require(Self.nowPlaying(["MPG321CX", "PD3205U"]))
                let capsule = Self.idealSize(NowPlayingCapsule(badge: badge, animates: false))
                let item = Self.item(subscribers: 123_400)
                let inset = DesignTokens.Spacing.sm
                for width in Self.cardWidths {
                    let crowded = try Self.render(Self.card(item, inUse: badge, hasUpdate: true), width: width, height: width, in: drawing)
                    let withoutResolution = try Self.render(
                        Self.card(item, inUse: badge, hasUpdate: true, showsResolution: false), width: width, height: width, in: drawing
                    )
                    let alone = try Self.render(
                        Self.card(item, inUse: badge, isInLibrary: false, showsResolution: false), width: width, height: width, in: drawing
                    )
                    let label = "\(drawing.testDescription) \(language.rawValue) \(String(format: "%.1f", width))pt"
                    let origin = CGPoint(x: inset, y: inset)
                    let rowShare = Self.differingShare(
                        crowded, at: origin, withoutResolution, at: origin, size: CGSize(width: width - 2 * inset, height: capsule.height)
                    )
                    #expect(
                        rowShare <= 0.002,
                        "\(label): the resolution badge outlasts the update's caption (\(String(format: "%.3f", rowShare)) of the row differs)"
                    )
                    let trailing = CGPoint(x: width / 2, y: inset)
                    let trailingShare = Self.differingShare(
                        crowded, at: trailing, alone, at: trailing, size: CGSize(width: width / 2 - inset, height: capsule.height)
                    )
                    #expect(trailingShare > 0.02, "\(label): the update badge is gone")
                }
            }
        }
    }

    @Test("Control: where all three fit, the resolution badge differs from the row without it", arguments: Drawing.all)
    func resolutionBadgeIsNoticed(in drawing: Drawing) throws {
        try AppLanguageOverride.with(.spanish) {
            let badge = try #require(Self.nowPlaying(["MPG321CX", "PD3205U"]))
            let capsule = Self.idealSize(NowPlayingCapsule(badge: badge, animates: false))
            let item = Self.item(subscribers: 123_400)
            let inset = DesignTokens.Spacing.sm
            // Wide enough for the capsule, "4K" and Spanish's caption, the longest, side by side.
            let side: CGFloat = 320
            let crowded = try Self.render(Self.card(item, inUse: badge, hasUpdate: true), width: side, height: side, in: drawing)
            let withoutResolution = try Self.render(
                Self.card(item, inUse: badge, hasUpdate: true, showsResolution: false), width: side, height: side, in: drawing
            )
            let origin = CGPoint(x: inset, y: inset)
            let share = Self.differingShare(
                crowded, at: origin, withoutResolution, at: origin, size: CGSize(width: side - 2 * inset, height: capsule.height)
            )
            #expect(share > 0.02, "\(drawing.testDescription): a resolution badge beside the update reads as absent (\(share))")
        }
    }
}
#endif
