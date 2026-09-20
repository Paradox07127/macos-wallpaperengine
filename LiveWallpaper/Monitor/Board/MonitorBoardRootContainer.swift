import LiveWallpaperCore
import SwiftUI

struct MonitorBoardRootContainer: View {
    @ObservedObject var model: InteractionModel
    @ObservedObject var data: DataModel
    let reduceMotion: Bool
    var suspended: Bool = false
    var preview: MonitorBoardPreview?
    var weatherService: WeatherReactiveService?
    var logicalSize: CGSize?
    /// Forces painted (non-glass) cards: offscreen capture of a `glassEffect` subtree would come back as holes.
    var forcesOpaquePanels: Bool = false

    private let overlayContent: AnyView

    init(
        model: InteractionModel,
        data: DataModel,
        reduceMotion: Bool,
        suspended: Bool = false,
        preview: MonitorBoardPreview? = nil,
        weatherService: WeatherReactiveService? = nil,
        logicalSize: CGSize? = nil,
        forcesOpaquePanels: Bool = false,
        @ViewBuilder overlayContent: () -> some View = { EmptyView() }
    ) {
        self.model = model
        self.data = data
        self.reduceMotion = reduceMotion
        self.suspended = suspended
        self.preview = preview
        self.weatherService = weatherService
        self.logicalSize = logicalSize
        self.forcesOpaquePanels = forcesOpaquePanels
        self.overlayContent = AnyView(overlayContent())
    }

    var body: some View {
        scaled.appLanguageScoped(defaults: .appScoped())
            .environment(\.monitorForcesOpaquePanels, forcesOpaquePanels)
    }

    @ViewBuilder
    private var scaled: some View {
        if let logicalSize, logicalSize.width > 0, logicalSize.height > 0 {
            GeometryReader { proxy in
                let scale = Self.previewScale(available: proxy.size, logical: logicalSize)
                board
                    .frame(width: logicalSize.width, height: logicalSize.height)
                    // The one place the board is shrunk. SwiftUI applies the
                    // inverse to its own hit testing, which an AppKit-side
                    // scale on the host would not reach.
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .environment(\.monitorRenderScale, scale)
            }
        } else {
            board
        }
    }

    private var board: some View {
        ZStack(alignment: .topLeading) {
            RootView(model: model, data: data, preview: preview)
            overlayContent
        }
        .environment(\.monitorReduceMotion, reduceMotion)
        .environment(\.monitorSuspended, suspended)
        .environment(\.monitorWeather, weatherService)
    }

    /// How far a `logical`-sized board is shrunk to fit `available`. 1 whenever
    /// there is nothing to shrink, so a desktop board is never scaled.
    static func previewScale(available: CGSize, logical: CGSize?) -> CGFloat {
        guard let logical, logical.width > 0, available.width > 0 else { return 1 }
        return available.width / logical.width
    }
}
