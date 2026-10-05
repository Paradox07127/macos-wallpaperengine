#if !LITE_BUILD
import WebKit

@MainActor
enum WebCacheMaintenance {
    /// Use WebKit's owner API. Cookies, local storage, IndexedDB and service
    /// worker registrations are persisted wallpaper data and must be retained.
    static func clear() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: .distantPast
        )
    }
}
#endif
