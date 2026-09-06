@testable import LiveWallpaper
import Testing

/// The Now Playing layer used to multiply its three visibility factors together
/// onto every pixel: the opacity dial, the text-brightness dial, and the paused
/// dim. A user who had dialled the layer down and then paused read the title at
/// `opacity × brightness × 0.55`. `NowPlayingVisibility` keeps them apart — this
/// suite is the statement of which factor is allowed to reach which part.
@Suite("Now Playing visibility keeps one dial per part of the tile")
struct NowPlayingVisibilityTests {
    private typealias Visibility = NowPlayingVisibility
    private typealias Backing = NowPlayingVisibility.TextBacking

    private static let opacityRange = NowPlayingOptions.Limits.opacity
    private static let brightnessRange = NowPlayingOptions.Limits.textBrightness

    private func resolve(
        opacity: Double = NowPlayingOptions.Defaults.opacity,
        brightness: Double = NowPlayingOptions.Defaults.textBrightness,
        dimmed: Bool = false,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) -> Visibility {
        var options = NowPlayingOptions()
        options.opacity = opacity
        options.textBrightness = brightness
        return Visibility.resolve(
            options: options,
            dimmed: dimmed,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    /// nil means "no plate at all" — the shipped borderless look.
    private func plateOpacity(_ backing: Backing) -> Double? {
        switch backing {
        case .shadow: nil
        case let .plate(opacity): opacity
        case .opaquePlate: 1
        }
    }

    // MARK: The reported bug — paused type went unreadable

    /// The core of R10: pausing changes nothing about how bright the type is
    /// drawn, at any position of the opacity dial.
    @Test(
        "Pausing leaves every text factor exactly where playing had it",
        arguments: [0.2, 0.5, 0.9, 1.0]
    )
    func pauseDoesNotTouchText(opacity: Double) {
        let playing = resolve(opacity: opacity, dimmed: false)
        let paused = resolve(opacity: opacity, dimmed: true)

        #expect(paused.text == playing.text)
        #expect(paused.layer == playing.layer)
        #expect(paused.controls == playing.controls)
        #expect(paused.textBacking == playing.textBacking)
    }

    /// The other half of the same statement: the dim did not get deleted, it got
    /// narrowed. Cover art and the platter still recede while paused.
    @Test("The paused dim reaches the cover and nothing else")
    func pauseDimReachesOnlyArt() {
        let playing = resolve(dimmed: false)
        let paused = resolve(dimmed: true)

        #expect(playing.art == 1)
        #expect(paused.art == Visibility.pausedArtDim)
        #expect(paused.art < playing.art, "a paused cover must still recede")
        #expect(paused.text == 1, "brightness is the only thing that scales type")
        #expect(paused.controls == 1)
    }

    // MARK: The opacity dial stays a whole-layer dial

    /// The dial is deliberately still allowed to fade the type — that is what
    /// the user asked it for — but the floor of the published range must leave
    /// something on screen, and by then the type is on a plate.
    @Test("At the lowest opacity the type is still drawn, and on a plate")
    func lowestOpacityKeepsTypeAndGainsAPlate() {
        let floor = Self.opacityRange.lowerBound
        let visibility = resolve(opacity: floor, brightness: Self.brightnessRange.lowerBound)

        #expect(visibility.layer == floor)
        #expect(visibility.layer * visibility.text > 0, "the type must not fade to nothing")

        let plate = plateOpacity(visibility.textBacking)
        #expect(plate != nil, "a dialled-down layer needs a ground under the type")
        #expect((plate ?? 0) > 0)
    }

    /// The counterpart guard: an untouched layer keeps the borderless look, so
    /// the plate cannot creep into the default presentation.
    @Test("An untouched layer draws no plate")
    func defaultsStayPlateless() {
        #expect(resolve().textBacking == .shadow)
    }

    /// The plate is a response to the dial, so it may never get weaker as the
    /// dial gets lower.
    @Test("The plate only ever strengthens as the dial drops")
    func plateGrowsMonotonically() {
        let steps = stride(
            from: Self.opacityRange.upperBound, through: Self.opacityRange.lowerBound, by: -0.05
        )
        var previous = 0.0
        for opacity in steps {
            let alpha = plateOpacity(resolve(opacity: opacity).textBacking) ?? 0
            #expect(alpha >= previous, "opacity \(opacity) drew a weaker plate than the step above it")
            previous = alpha
        }
        #expect(previous > 0, "the bottom of the range must end up with a plate")
    }

    // MARK: Brightness is a type dial only

    @Test("Text brightness reaches type only", arguments: [0.5, 0.75, 1.0])
    func brightnessReachesTypeOnly(brightness: Double) {
        let visibility = resolve(brightness: brightness, dimmed: true)

        #expect(visibility.text == brightness)
        #expect(visibility.controls == 1, "the transport row is not type")
        #expect(visibility.art == Visibility.pausedArtDim, "the cover follows the pause, not the dial")
        #expect(visibility.layer == NowPlayingOptions.Defaults.opacity)
        #expect(
            visibility.textBacking == resolve(dimmed: true).textBacking,
            "brightness must not move the backing under the type"
        )
    }

    // MARK: Accessibility display settings

    @Test(
        "Reduce Transparency makes the backing opaque at every dial position",
        arguments: [0.2, 0.6, 1.0]
    )
    func reduceTransparencyMakesTheBackingOpaque(opacity: Double) {
        #expect(resolve(opacity: opacity, reduceTransparency: true).textBacking == .opaquePlate)
        #expect(
            resolve(opacity: opacity, reduceTransparency: true, increaseContrast: true).textBacking
                == .opaquePlate,
            "Reduce Transparency already gives the most contrast there is"
        )
    }

    /// Increase Contrast on its own keeps the translucent plate but must always
    /// land above whatever the dial alone would have drawn.
    @Test("Increase Contrast raises the plate above anything the dial produces", arguments: [0.2, 0.6, 1.0])
    func increaseContrastRaisesThePlate(opacity: Double) {
        let plain = plateOpacity(resolve(opacity: opacity).textBacking) ?? 0
        let contrasted = plateOpacity(resolve(opacity: opacity, increaseContrast: true).textBacking) ?? 0

        #expect(contrasted > plain, "opacity \(opacity) gained no contrast from the setting")
        #expect(contrasted < 1, "only Reduce Transparency goes fully opaque")
    }

    /// Neither setting is allowed to touch the factors themselves — they decide
    /// the ground under the type, not how bright anything is drawn.
    @Test("The accessibility settings move the backing, not the factors")
    func accessibilitySettingsOnlyMoveTheBacking() {
        let plain = resolve(opacity: 0.6, brightness: 0.8, dimmed: true)
        for visibility in [
            resolve(opacity: 0.6, brightness: 0.8, dimmed: true, reduceTransparency: true),
            resolve(opacity: 0.6, brightness: 0.8, dimmed: true, increaseContrast: true),
        ] {
            #expect(visibility.layer == plain.layer)
            #expect(visibility.text == plain.text)
            #expect(visibility.art == plain.art)
            #expect(visibility.controls == plain.controls)
        }
    }
}
