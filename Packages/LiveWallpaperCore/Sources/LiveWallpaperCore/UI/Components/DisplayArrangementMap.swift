import SwiftUI

public struct DisplayArrangementItem<ID: Hashable>: Identifiable {
    public let id: ID
    /// The display's frame in global display space (AppKit coordinates, y-up).
    public let frame: CGRect

    public init(id: ID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// Pure geometry behind `DisplayArrangementMap`, split out so the y-flip and the
/// fit maths are testable without a view host.
public enum DisplayArrangementLayout {
    /// Union of every display frame in global display space.
    public static func bounds(of frames: [CGRect]) -> CGRect {
        frames.reduce(CGRect.null) { $0.union($1) }
    }

    /// Largest factor that fits `bounds` inside `size`.
    public static func scale(bounds: CGRect, in size: CGSize) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        return min(size.width / bounds.width, size.height / bounds.height)
    }

    /// A display's rect in the map's own top-left-origin space. Global display
    /// space is y-up, so the tile's y is measured down from the union's top edge.
    public static func tileRect(
        for frame: CGRect,
        bounds: CGRect,
        scale: CGFloat,
        gap: CGFloat
    ) -> CGRect {
        CGRect(
            x: (frame.minX - bounds.minX) * scale + gap / 2,
            y: (bounds.maxY - frame.maxY) * scale + gap / 2,
            width: max(frame.width * scale - gap, 1),
            height: max(frame.height * scale - gap, 1)
        )
    }
}

/// Mirrors the system's display arrangement: every tile keeps its real relative
/// position and aspect ratio, scaled to fit a fixed-height band. Read-only —
/// macOS owns the layout; this only shows which panel sits where.
public struct DisplayArrangementMap<ID: Hashable, TileContent: View>: View {
    private let items: [DisplayArrangementItem<ID>]
    private let height: CGFloat
    private let gap: CGFloat
    private let content: (DisplayArrangementItem<ID>, CGSize) -> TileContent

    /// - Parameters:
    ///   - height: the band the map is scaled into; the arrangement is centred in it.
    ///   - gap: inset applied to every tile, so touching displays read as separate.
    ///   - content: receives the tile's on-screen size — small tiles can drop their label.
    public init(
        items: [DisplayArrangementItem<ID>],
        height: CGFloat = 150,
        gap: CGFloat = 6,
        @ViewBuilder content: @escaping (DisplayArrangementItem<ID>, CGSize) -> TileContent
    ) {
        self.items = items
        self.height = height
        self.gap = gap
        self.content = content
    }

    public var body: some View {
        let bounds = DisplayArrangementLayout.bounds(of: items.map(\.frame))
        if items.isEmpty || bounds.width <= 0 || bounds.height <= 0 {
            EmptyView()
        } else {
            GeometryReader { geo in
                let scale = DisplayArrangementLayout.scale(bounds: bounds, in: geo.size)
                ZStack(alignment: .topLeading) {
                    ForEach(items) { item in
                        let rect = DisplayArrangementLayout.tileRect(
                            for: item.frame,
                            bounds: bounds,
                            scale: scale,
                            gap: gap
                        )
                        content(item, rect.size)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .frame(width: bounds.width * scale, height: bounds.height * scale, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: height)
            .accessibilityElement(children: .contain)
        }
    }
}
