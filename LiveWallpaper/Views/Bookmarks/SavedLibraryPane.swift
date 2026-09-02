import LiveWallpaperCore
import SwiftUI

enum SavedLibraryTab: String, CaseIterable, Identifiable {
    case bookmarks
    case schemes

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .bookmarks: "Bookmarks"
        case .schemes: "Schemes"
        }
    }

    var systemImage: String {
        switch self {
        case .bookmarks: "bookmark.fill"
        case .schemes: "square.stack.3d.up.fill"
        }
    }
}

/// One page for both saved-thing libraries, switched by a centred toolbar capsule.
///
/// A bookmark is one wallpaper; a scheme is a whole display's setup. They are two
/// archives of the same kind of act — "keep this so I can put it back" — and they
/// had identical page shapes, so two sidebar rows bought a second click and a
/// second place to look. The capsule is this page's title: with the sidebar row
/// selected and the segments named, a separate heading would say it a third time.
struct SavedLibraryPane: View {
    let initialTab: SavedLibraryTab

    @AppStorage("loomscreen.savedLibrary.selectedTab.v1", store: .appScoped())
    private var selectedTab: SavedLibraryTab = .bookmarks

    @State private var didApplyInitialTab = false

    var body: some View {
        Group {
            switch selectedTab {
            case .bookmarks: LibraryView()
            case .schemes: SchemeLibraryView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Saved library tab", selection: $selectedTab) {
                    ForEach(SavedLibraryTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(Text("Saved library tab"))
            }
        }
        // Once, not on every appearance: `onAppear` fires again each time the
        // page is navigated back to, and re-applying there overwrote whichever
        // tab the user had left the capsule on.
        .onAppear {
            guard !didApplyInitialTab else { return }
            didApplyInitialTab = true
            selectedTab = initialTab
        }
    }
}
