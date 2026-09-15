import AppKit
import LiveWallpaperCore
import Observation
import SwiftUI

/// The same geometry calculation serves all three containers, including resize.
struct Geometry {
    let columns: Int
    let side: CGFloat
    let inset = DesignTokens.LibraryGrid.horizontalPadding
    let spacing = DesignTokens.LibraryGrid.spacing
    init(width: CGFloat) {
        let limits = DesignTokens.LibraryGrid.columnWidths(for: .medium, aspect: .square)
        let available = max(limits.min, width - 2 * inset)
        columns = max(1, Int((available + spacing) / (limits.min + spacing)))
        side = min(limits.max, (available - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }
    var pitch: CGFloat { side + spacing }
}

@MainActor @Observable final class CardState: Identifiable {
    let id: UInt64
    let item: WorkshopQueryItem
    let entry: WPEHistoryEntry?
    let previewKey: String
    var selected = false
    var materialized = true
    init(item: WorkshopQueryItem, entry: WPEHistoryEntry?) {
        self.id = item.id; self.item = item; self.entry = entry
        previewKey = entry?.origin.workshopID ?? item.previewImageURL?.lastPathComponent ?? ""
    }
}

@MainActor @Observable final class Library {
    var cards: [CardState] = []
    @ObservationIgnored var byID: [UInt64: CardState] = [:]
    @ObservationIgnored var selectedID: UInt64?
    @ObservationIgnored var selectionChanged: (() -> Void)?
    func select(_ id: UInt64) {
        if let previous = selectedID { byID[previous]?.selected = false }
        selectedID = selectedID == id ? nil : id
        if let selectedID { byID[selectedID]?.selected = true }
        Metrics.clicks += 1
        Metrics.clickTimes.append(CACurrentMediaTime())
        selectionChanged?()
    }
}

struct Card: View {
    let state: CardState
    let library: Library
    var body: some View {
        Group {
            if !state.materialized {
                Color.clear
            } else if let entry = state.entry {
                HistoryRow(entry: entry, isActive: false, allowsInlineApply: true,
                           isSelected: state.selected, onTap: { library.select(state.id) },
                           onRemove: {}, onBookmark: {})
            } else {
                BrowseCard(item: state.item, isSelected: state.selected,
                           cardPreferences: GalleryCardPreferences(),
                           reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                           onSelect: { library.select(state.id) }).equatable()
            }
        }
        .id(state.id)
    }
}

struct SwiftGrid: View {
    let library: Library
    let eager: Bool
    var body: some View {
        GeometryReader { proxy in
            let geometry = Geometry(width: proxy.size.width)
            ScrollView {
                Group {
                    if eager {
                        EagerTileLayout(geometry: geometry) {
                            ForEach(library.cards) { card in
                                Card(state: card, library: library)
                                    .frame(width: geometry.side, height: geometry.side)
                            }
                        }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(geometry.side), spacing: geometry.spacing), count: geometry.columns), alignment: .leading, spacing: geometry.spacing) {
                            ForEach(library.cards) { card in
                                Card(state: card, library: library).frame(width: geometry.side, height: geometry.side)
                            }
                        }
                    }
                }
                .padding(.horizontal, geometry.inset)
                .padding(.vertical, DesignTokens.LibraryGrid.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Flat IDs survive column-count changes. Fixed tile sizes avoid measuring each
/// child to discover row heights. Eager creation remains the intended trade-off.
struct EagerTileLayout: Layout {
    let geometry: Geometry
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = (subviews.count + geometry.columns - 1) / geometry.columns
        return CGSize(width: CGFloat(geometry.columns) * geometry.pitch - geometry.spacing,
                      height: max(0, CGFloat(rows) * geometry.pitch - geometry.spacing))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index % geometry.columns) * geometry.pitch,
                                              y: bounds.minY + CGFloat(index / geometry.columns) * geometry.pitch),
                                 anchor: .topLeading, proposal: ProposedViewSize(width: geometry.side, height: geometry.side))
        }
    }
}

@MainActor final class HostedCard: NSCollectionViewItem {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var boundID: UInt64?
    override func loadView() { host.sizingOptions = []; view = host; Metrics.hostsCreated += 1 }
    func bind(_ state: CardState, library: Library) {
        // Selection mutates CardState directly; it never replaces rootView.
        guard boundID != state.id else { return }
        boundID = state.id
        host.rootView = AnyView(Card(state: state, library: library))
        Metrics.hostsBound += 1
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        boundID = nil; host.rootView = AnyView(EmptyView())
    }
}

@MainActor final class CollectionHost: NSObject, NSCollectionViewDelegateFlowLayout {
    let scroll = NSScrollView()
    let collection = NSCollectionView()
    let library: Library
    private var dataSource: NSCollectionViewDiffableDataSource<Int, UInt64>!
    init(library: Library) {
        self.library = library
        super.init()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = DesignTokens.LibraryGrid.spacing
        layout.minimumLineSpacing = DesignTokens.LibraryGrid.spacing
        layout.sectionInset = NSEdgeInsets(top: DesignTokens.LibraryGrid.verticalPadding,
                                           left: DesignTokens.LibraryGrid.horizontalPadding,
                                           bottom: DesignTokens.LibraryGrid.verticalPadding,
                                           right: DesignTokens.LibraryGrid.horizontalPadding)
        collection.collectionViewLayout = layout
        collection.delegate = self
        // Product card buttons own selection in every variant.
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(HostedCard.self, forItemWithIdentifier: .init("card"))
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false; scroll.documentView = collection
        dataSource = NSCollectionViewDiffableDataSource<Int, UInt64>(collectionView: collection) { [weak self] collection, index, id in
            guard let self, let state = self.library.byID[id],
                  let cell = collection.makeItem(withIdentifier: .init("card"), for: index) as? HostedCard else { return nil }
            cell.bind(state, library: self.library)
            return cell
        }
        reload()
    }
    func reload() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UInt64>()
        snapshot.appendSections([0]); snapshot.appendItems(library.cards.map(\.id))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            dataSource.apply(snapshot, animatingDifferences: true)
        }
    }
    func collectionView(_: NSCollectionView, layout _: NSCollectionViewLayout, sizeForItemAt _: IndexPath) -> NSSize {
        let side = Geometry(width: scroll.contentSize.width).side
        return NSSize(width: side, height: side)
    }
}

/// A small lookahead uses existing caches/decoders; no full-GIF predecode.
@MainActor final class Preheater {
    private var tasks: [String: Task<Void, Never>] = [:]
    func update(_ cards: ArraySlice<CardState>) {
        guard arg("preheat", "on") == "on" else { return }
        let desired = Set(cards.map(\.previewKey))
        for key in Array(tasks.keys) where !desired.contains(key) { tasks.removeValue(forKey: key)?.cancel() }
        for card in cards where tasks[card.previewKey] == nil {
            tasks[card.previewKey] = Task {
                if let entry = card.entry {
                    let prepared = await PreviewWorkGate.shared.runDetached { () -> (URL, String)? in
                        guard let url = entry.origin.sourcePreviewURL,
                              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                        return (url, "\(modified.timeIntervalSinceReferenceDate)|\(WPEPreviewSize.tile.maxPixelSize)|\(url.absoluteString)")
                    }
                    guard !Task.isCancelled, let (url, key) = prepared,
                          WPEPreviewDecodedCache.shared.object(forKey: key as NSString) == nil else { return }
                    let decoded = await workflowDecode(url, bookmark: entry.origin.sourceFolderBookmark)
                    guard !Task.isCancelled, let decoded,
                          WPEPreviewDecodedCache.shared.object(forKey: key as NSString) == nil else { return }
                    WPEImageCacheMeter.recordInsert(decoded, cost: decoded.estimatedCost, in: .scenePreviewDecoded)
                    WPEPreviewDecodedCache.shared.setObject(decoded, forKey: key as NSString, cost: decoded.estimatedCost)
                } else if let url = card.item.previewImageURL {
                    _ = await WorkshopPreviewImageLoader.shared.loadAsset(url)
                }
            }
        }
    }
    func cancel() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}
