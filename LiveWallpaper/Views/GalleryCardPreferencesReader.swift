import LiveWallpaperCore
import SwiftUI

private struct GalleryCardPreferencesReader: ViewModifier {
    @AppStorage(CardBadgeSettings.showsRating, store: .appScoped()) private var showsRating = true
    @AppStorage(CardBadgeSettings.showsResolution, store: .appScoped()) private var showsResolution = true
    @AppStorage(CardBadgeSettings.showsInLibrary, store: .appScoped()) private var showsInLibrary = true
    @AppStorage(CardBadgeSettings.showsUpdate, store: .appScoped()) private var showsUpdate = true
    @AppStorage(CardBadgeSettings.showsInUse, store: .appScoped()) private var showsInUse = true
    @AppStorage(MatureContentSettings.blursThumbnails, store: .appScoped()) private var blursMature = true

    func body(content: Content) -> some View {
        content.environment(
            \.galleryCardPreferences,
            GalleryCardPreferences(
                showsRating: showsRating,
                showsResolution: showsResolution,
                showsInLibrary: showsInLibrary,
                showsUpdate: showsUpdate,
                showsInUse: showsInUse,
                blursMatureThumbnails: blursMature
            )
        )
    }
}

extension View {
    func providesGalleryCardPreferences() -> some View {
        modifier(GalleryCardPreferencesReader())
    }

    @MainActor
    func matureContentConfirmation(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        alert("Show mature content?", isPresented: isPresented) {
            Button(role: .cancel) {} label: { Text("Cancel") }
            Button(role: .destructive) {
                MatureContentSettings.confirm()
                onConfirm()
            } label: {
                Text("I am 18 or older")
            }
        } message: {
            Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
        }
    }
}

enum MatureContentSettings {
    static let blursThumbnails = "loomscreen.workshop.blurMatureThumbnails.v1"
    static let confirmed = "loomscreen.workshop.matureContentConfirmed.v1"

    @MainActor
    static var isConfirmed: Bool {
        UserDefaults.appScoped().bool(forKey: confirmed)
    }

    @MainActor
    static func confirm() {
        UserDefaults.appScoped().set(true, forKey: confirmed)
    }
}
