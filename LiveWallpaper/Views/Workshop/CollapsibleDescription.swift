#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct CollapsibleDescription: View {
    let text: String
    @Binding var isExpanded: Bool
    /// nil crops the collapsed text to `collapsedHeight` and fades the cut; a value truncates it to
    /// that many lines instead, for columns too narrow to spend 116pt on a description.
    var collapsedLineLimit: Int?

    /// ~6 lines of body copy before we crop + fade.
    private let collapsedHeight: CGFloat = 116

    /// The text's height with no crop of any kind.
    @State private var fullHeight: CGFloat = 0
    /// The height `collapsedLineLimit` leaves; equal to `fullHeight` when there is no limit.
    @State private var limitedHeight: CGFloat = 0

    /// A height crop can only be told from the box it fills; a line crop shows up as the two
    /// measurements disagreeing, which holds whether or not the text is expanded right now.
    static func isExpandable(
        fullHeight: CGFloat, limitedHeight: CGFloat, collapsedHeight: CGFloat, lineLimit: Int?
    ) -> Bool {
        guard lineLimit != nil else { return fullHeight > collapsedHeight + 1 }
        return fullHeight > limitedHeight + 1
    }

    /// nil means the text keeps its intrinsic height: expanded, or cropped by lines rather than points.
    static func cropHeight(
        fullHeight: CGFloat, collapsedHeight: CGFloat, collapsed: Bool, lineLimit: Int?
    ) -> CGFloat? {
        guard fullHeight > 0, lineLimit == nil else { return nil }
        return collapsed ? collapsedHeight : fullHeight
    }

    private var isExpandable: Bool {
        Self.isExpandable(
            fullHeight: fullHeight, limitedHeight: limitedHeight,
            collapsedHeight: collapsedHeight, lineLimit: collapsedLineLimit
        )
    }

    var body: some View {
        let collapsed = isExpandable && !isExpanded
        VStack(alignment: .leading, spacing: 4) {
            description(collapsed: collapsed)
            if isExpandable {
                Button {
                    withAnimation(.easeInOut(duration: 0.28)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Show less" : "Show more")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(isExpanded ? "Show less" : "Show more"))
            }
        }
        .onChange(of: text) { _, _ in
            fullHeight = 0
            limitedHeight = 0
            isExpanded = false
        }
    }

    private func description(collapsed: Bool) -> some View {
        Text(verbatim: text)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(collapsed ? collapsedLineLimit : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) { rulers }
            .frame(
                height: Self.cropHeight(
                    fullHeight: fullHeight, collapsedHeight: collapsedHeight,
                    collapsed: collapsed, lineLimit: collapsedLineLimit
                ),
                alignment: .top
            )
            .clipped()
            .mask(collapsed && collapsedLineLimit == nil ? AnyView(fadeMask) : AnyView(Rectangle()))
    }

    /// Hidden copies rather than a reader on the visible text: `lineLimit` shortens what the
    /// visible text reports, which is the very difference the toggle is looking for.
    private var rulers: some View {
        ZStack(alignment: .topLeading) {
            ruler(lineLimit: nil) { fullHeight = $0 }
            if collapsedLineLimit != nil {
                ruler(lineLimit: collapsedLineLimit) { limitedHeight = $0 }
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func ruler(lineLimit: Int?, report: @escaping (CGFloat) -> Void) -> some View {
        Text(verbatim: text)
            .font(.body)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
    }

    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.72),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif
