#if !LITE_BUILD
@testable import LiveWallpaper
import Testing

@Suite("Workshop page number window")
struct BrowsePageWindowTests {
    @Test("Short results show every page", arguments: [1, 3, 5])
    func shortResults(current: Int) {
        #expect(BrowsePageWindow.pages(currentPage: current, totalPages: 5, hasNextPage: current < 5) == [1, 2, 3, 4, 5])
    }

    @Test("Long results keep the current page and both endpoints", arguments: [1, 2, 50, 999, 1000])
    func longResults(current: Int) {
        let pages = BrowsePageWindow.pages(currentPage: current, totalPages: 1000, hasNextPage: current < 1000)
        #expect(pages.first == 1)
        #expect(pages.last == 1000)
        #expect(pages.contains(current))
        #expect(pages == pages.sorted())
        #expect(Set(pages).count == pages.count)
        #expect(pages.count <= 7)
        #expect(pages.allSatisfy { (1 ... 1000).contains($0) })
    }

    @Test("The five-page window shifts at either boundary")
    func boundaries() {
        #expect(BrowsePageWindow.pages(currentPage: 1, totalPages: 1000, hasNextPage: true) == [1, 2, 3, 4, 5, 1000])
        #expect(BrowsePageWindow.pages(currentPage: 50, totalPages: 1000, hasNextPage: true) == [1, 48, 49, 50, 51, 52, 1000])
        #expect(BrowsePageWindow.pages(currentPage: 1000, totalPages: 1000, hasNextPage: false) == [1, 996, 997, 998, 999, 1000])
    }

    @Test("Unknown totals never advertise unconfirmed future pages")
    func unknownTotal() {
        #expect(BrowsePageWindow.pages(currentPage: 1, totalPages: nil, hasNextPage: true) == [1, 2])
        #expect(BrowsePageWindow.pages(currentPage: 3, totalPages: nil, hasNextPage: false) == [1, 2, 3])
        #expect(BrowsePageWindow.pages(currentPage: 50, totalPages: nil, hasNextPage: true) == [1, 47, 48, 49, 50, 51])
        #expect(BrowsePageWindow.pages(currentPage: 1000, totalPages: nil, hasNextPage: true).last == 1000)
    }

    @Test("Narrow layouts retain the selected page and endpoint shortcuts")
    func compactWindow() {
        #expect(BrowsePageWindow.pages(currentPage: 50, totalPages: 1000, hasNextPage: true, windowSize: 3) == [1, 49, 50, 51, 1000])
    }
}
#endif
