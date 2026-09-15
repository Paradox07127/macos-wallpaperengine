import AppKit
import LiveWallpaperCore
import Observation
import SwiftUI

@MainActor @Observable final class ProbeModel {
    var items: [WorkshopQueryItem] = []
    var selected: UInt64?
    var installed: [UInt64: WPEHistoryEntry] = [:]
    var values: [String: WallpaperEngineProjectPropertyValue] = [:]
    var expanded: Set<String> = []
    var edits = 0
    func binding(_ p: WallpaperEngineProjectPropertySchema.Property) -> Binding<Double> {
        Binding(get: { self.values[p.key]?.numberValue ?? p.minimum ?? 0 }, set: {
            self.values[p.key] = .number(PropertyValueLogic.normalizedSliderValue($0, for: p)); self.edits += 1
        })
    }
}

struct SceneProbeView: View {
    var model: ProbeModel
    let schema: WallpaperEngineProjectPropertySchema
    let variant: String
    var body: some View {
        let presentation = WPEProjectSettingsPresentation(schema: schema, overrides: model.values, excludedKeys: ["schemecolor"])
        let rows = presentation.rows(expandedSectionIDs: model.expanded)
        ScrollView {
            GroupBox {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case let .sectionHeader(section):
                            Button {
                                if model.expanded.contains(section.id) {
                                    model.expanded.remove(section.id)
                                } else {
                                    model.expanded.insert(section.id)
                                }
                            } label: {
                                HStack { Text(verbatim: section.title); Spacer(); Image(systemName: "chevron.right") }
                            }.buttonStyle(.plain).accessibilityAddTraits(.isHeader).frame(minHeight: 44)
                        case let .property(p):
                            SettingRow(icon: WPEPropertyRowIcon.symbol(for: p.type), verbatimTitle: p.displayText) {
                                control(p)
                            }.frame(minHeight: 44).overlay(alignment: .bottom) { Divider() }
                        }
                    }
                }
            }.groupBoxStyle(ContainerGroupBoxStyle()).padding(DesignTokens.Spacing.md)
        }
    }

    @ViewBuilder func control(_ p: WallpaperEngineProjectPropertySchema.Property) -> some View {
        switch p.type {
        case .slider:
            HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                slider(p).frame(width: DesignTokens.Inspector.sliderWidth).controlSize(.small)
                    .accessibilityLabel(Text(verbatim: p.displayText))
                Text(verbatim: PropertyValueLogic.formattedNumber(model.values[p.key]?.numberValue ?? 0, for: p))
                    .font(DesignTokens.Typography.metric).foregroundStyle(.secondary)
                    .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
            }
        case .bool:
            Toggle("", isOn: Binding(get: { model.values[p.key]?.boolValue ?? false }, set: { model.values[p.key] = .bool($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(p.displayText)
        case .combo:
            Picker("", selection: Binding(get: { model.values[p.key] ?? .string("") }, set: { model.values[p.key] = $0 })) {
                ForEach(p.options) { option in Text(verbatim: option.displayLabel).tag(option.value) }
            }.labelsHidden().pickerStyle(.menu).frame(minWidth: 96).accessibilityLabel(p.displayText)
        case .color:
            ColorPicker("", selection: Binding(get: { PropertyValueLogic.cgColor(from: model.values[p.key]?.stringValue ?? "1 1 1") }, set: { model.values[p.key] = .string(PropertyValueLogic.colorString(from: $0)) }), supportsOpacity: false).labelsHidden().controlSize(.small).accessibilityLabel(p.displayText)
        case .textinput:
            TextField("", text: Binding(get: { model.values[p.key]?.stringValue ?? "" }, set: { model.values[p.key] = .string($0) })).textFieldStyle(.roundedBorder).frame(width: 132).controlSize(.small).accessibilityLabel(p.displayText)
        default: EmptyView()
        }
    }

    @ViewBuilder func slider(_ p: WallpaperEngineProjectPropertySchema.Property) -> some View {
        if variant == "quantized" {
            QuantizedSlider(value: model.binding(p), in: PropertyValueLogic.sliderRange(for: p), step: PropertyValueLogic.sliderStep(for: p))
        } else if variant == "native" {
            NativePropertySlider(value: model.binding(p), property: p)
        } else if variant == "continuous" {
            Slider(value: model.binding(p), in: PropertyValueLogic.sliderRange(for: p))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.binding(p).wrappedValue += PropertyValueLogic.sliderStep(for: p)
                    case .decrement: model.binding(p).wrappedValue -= PropertyValueLogic.sliderStep(for: p)
                    @unknown default: break
                    }
                }
                .onKeyPress(.leftArrow) { model.binding(p).wrappedValue -= PropertyValueLogic.sliderStep(for: p); return .handled }
                .onKeyPress(.rightArrow) { model.binding(p).wrappedValue += PropertyValueLogic.sliderStep(for: p); return .handled }
        } else {
            Slider(value: model.binding(p), in: PropertyValueLogic.sliderRange(for: p), step: displayStep(p))
        }
    }

    func displayStep(_ p: WallpaperEngineProjectPropertySchema.Property) -> Double {
        if variant == "current" {
            return PropertyValueLogic.displaySliderStep(for: p)
        }
        let authored = PropertyValueLogic.sliderStep(for: p)
        let range = PropertyValueLogic.sliderRange(for: p)
        let cap = Double(variant) ?? 1000
        return authored * max(1, ((range.upperBound - range.lowerBound) / (cap - 1) / authored).rounded(.up))
    }
}

struct GridProbeView: View {
    var model: ProbeModel
    let reduceMotion: Bool
    var body: some View {
        ScrollView {
            LazyVGrid(columns: DesignTokens.LibraryGrid.columns(for: .medium, aspect: .square), spacing: DesignTokens.LibraryGrid.spacing) {
                ForEach(model.items) { item in
                    if let entry = model.installed[item.id] {
                        HistoryRow(entry: entry, isActive: false, allowsInlineApply: true, isSelected: model.selected == item.id, onTap: { model.selected = item.id }, onRemove: {}).id(item.id)
                    } else {
                        BrowseCard(item: item, isSelected: model.selected == item.id, cardPreferences: GalleryCardPreferences(), reduceMotion: reduceMotion, onSelect: { model.selected = item.id }).equatable().id(item.id)
                    }
                }
            }.libraryGridPadding()
        }
    }
}

@MainActor final class CollectionHost: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    let scroll = NSScrollView()
    let collection = NSCollectionView()
    let model: ProbeModel
    let reduceMotion: Bool
    var created = 0
    var configured = 0
    init(model: ProbeModel, reduceMotion: Bool) {
        self.model = model; self.reduceMotion = reduceMotion
        super.init()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = DesignTokens.LibraryGrid.spacing
        layout.minimumLineSpacing = DesignTokens.LibraryGrid.spacing
        layout.sectionInset = NSEdgeInsets(top: 14, left: 24, bottom: 14, right: 24)
        collection.collectionViewLayout = layout
        collection.dataSource = self; collection.delegate = self
        collection.register(HostedCard.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("card"))
        collection.isSelectable = true
        scroll.hasVerticalScroller = true
        scroll.documentView = collection
        scroll.drawsBackground = false
    }

    func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
        model.items.count
    }

    func collectionView(_: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collection.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("card"), for: indexPath) as? HostedCard else { preconditionFailure("Incorrect registered cell class") }
        configured += 1
        let item = model.items[indexPath.item]
        cell.host.rootView = cardContent(item)
        return cell
    }

    func cardContent(_ item: WorkshopQueryItem) -> AnyView {
        if let entry = model.installed[item.id] {
            return AnyView(HistoryRow(entry: entry, isActive: false, allowsInlineApply: true, isSelected: model.selected == item.id, onTap: { [weak self] in self?.select(item.id) }, onRemove: {}).id(item.id))
        }
        return AnyView(BrowseCard(item: item, isSelected: model.selected == item.id, cardPreferences: GalleryCardPreferences(), reduceMotion: reduceMotion, onSelect: { [weak self] in self?.select(item.id) }).id(item.id))
    }

    func select(_ id: UInt64) {
        model.selected = id
        if let index = model.items.firstIndex(where: { $0.id == id }) {
            let paths: Set<IndexPath> = [IndexPath(item: index, section: 0)]
            if collection.selectionIndexPaths != paths {
                collection.selectionIndexPaths = paths
            }
        }
        for cell in collection.visibleItems() {
            if let index = collection.indexPath(for: cell), let card = cell as? HostedCard {
                configureVisible(card, index.item)
            }
        }
    }

    func reload() {
        collection.reloadData()
        if let id = model.selected, let index = model.items.firstIndex(where: { $0.id == id }) {
            collection.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        } else {
            collection.selectionIndexPaths = []
        }
    }

    func configureVisible(_ cell: HostedCard, _ index: Int) {
        let item = model.items[index]
        cell.host.rootView = cardContent(item)
    }

    func collectionView(_: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let index = indexPaths.first {
            select(model.items[index.item].id)
        }
    }

    func collectionView(_: NSCollectionView, layout _: NSCollectionViewLayout, sizeForItemAt _: IndexPath) -> NSSize {
        let available = scroll.contentSize.width - 48
        let columns = max(1, floor((available + DesignTokens.LibraryGrid.spacing) / (184 + DesignTokens.LibraryGrid.spacing)))
        let width = min(DesignTokens.LibraryGrid.maximumColumnWidth, (available - (columns - 1) * DesignTokens.LibraryGrid.spacing) / columns)
        return NSSize(width: width, height: width)
    }
}

@MainActor final class HostedCard: NSCollectionViewItem {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    override func loadView() {
        view = host
    }

    override func prepareForReuse() {
        super.prepareForReuse(); host.rootView = AnyView(EmptyView())
    }
}
