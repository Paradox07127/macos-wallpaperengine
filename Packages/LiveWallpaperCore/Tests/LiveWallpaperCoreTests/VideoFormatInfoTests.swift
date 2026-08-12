import Testing
import CoreGraphics
@testable import LiveWallpaperCore

@Suite("VideoFormatInfo.badges")
struct VideoFormatInfoTests {

    @Test("Empty info yields no badges")
    func emptyInfoYieldsNoBadges() {
        let info = VideoFormatInfo()
        #expect(info.badges == [])
    }

    @Test("4K resolution surfaces .resolution4K")
    func fourKResolutionSurfaces() {
        let info = VideoFormatInfo(resolution: CGSize(width: 3840, height: 2160))
        #expect(info.badges == [.resolution4K])
    }

    @Test("8K resolution supersedes 4K and surfaces once")
    func eightKResolutionSupersedes() {
        let info = VideoFormatInfo(resolution: CGSize(width: 7680, height: 4320))
        #expect(info.badges == [.resolution8K])
    }

    @Test("HDR and ProRes flags compose with resolution in display order")
    func hdrAndProResComposeInOrder() {
        let info = VideoFormatInfo(
            codecFourCC: "apch",
            isHDR: true,
            resolution: CGSize(width: 3840, height: 2160)
        )
        #expect(info.badges == [.resolution4K, .hdr, .proRes])
    }

    @Test("displayLabel maps each case to its verbatim glyph")
    func displayLabelMapsToGlyph() {
        #expect(VideoFormatBadge.resolution4K.displayLabel == "4K")
        #expect(VideoFormatBadge.resolution8K.displayLabel == "8K")
        #expect(VideoFormatBadge.hdr.displayLabel == "HDR")
        #expect(VideoFormatBadge.proRes.displayLabel == "ProRes")
    }

    /// The Workshop's online grid derives this label from a Steam tag and the
    /// installed grid from the probed file; both go through this table so one
    /// wallpaper never reads "4K" on one screen and "2160p" on the other.
    @Test("resolutionShortLabel maps dimensions to the shared vocabulary", arguments: [
        (3840, 2160, "4K"),
        (4096, 2160, "4K"),
        (7680, 4320, "4K"),
        (2560, 1440, "1440p"),
        (1920, 1080, "1080p"),
        (1280, 720, "720p"),
        (640, 480, "SD"),
        (1080, 1920, "Portrait"),
        (3440, 1440, "UW"),
        (2560, 1080, "UW"),
        (7680, 2160, "Dual")
    ])
    func resolutionShortLabelMapsDimensions(width: Int, height: Int, expected: String) {
        #expect(VideoFormatInfo.resolutionShortLabel(width: width, height: height) == expected)
    }

    @Test("resolutionShortLabel rejects degenerate dimensions")
    func resolutionShortLabelRejectsDegenerate() {
        #expect(VideoFormatInfo.resolutionShortLabel(width: 0, height: 1080) == nil)
        #expect(VideoFormatInfo.resolutionShortLabel(width: 1920, height: 0) == nil)
        #expect(VideoFormatInfo(resolution: nil).resolutionShortLabel == nil)
    }

    @Test("The instance property reads the probed resolution")
    func instancePropertyReadsResolution() {
        let info = VideoFormatInfo(resolution: CGSize(width: 2560, height: 1440))
        #expect(info.resolutionShortLabel == "1440p")
    }
}
