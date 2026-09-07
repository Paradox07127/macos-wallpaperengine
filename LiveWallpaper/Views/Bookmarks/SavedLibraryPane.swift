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

/// Shared archive page for wallpaper bookmarks and display schemes.
struct SavedLibraryPane: View {
    @AppStorage("loomscreen.savedLibrary.selectedTab.v1", store: .appScoped())
    private var selectedTab: SavedLibraryTab = .bookmarks

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
    }
}
