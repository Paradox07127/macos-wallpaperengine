import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Bug report system wallpaper extension processes")
struct BugReporterExtensionProcessTests {
    private let bundled = "/Applications/Loomscreen.app/Contents/Extensions/SystemWallpaperProvider.appex"
    private let elsewhere = "/Users/alice/Library/Developer/Xcode/DerivedData/LW/Build/Products/Debug/Loomscreen.app/Contents/Extensions/SystemWallpaperProvider.appex"

    @Test("Each running copy gets a line, marked by whether it is the bundled one")
    func bundledAndForeignCopiesAreMarked() {
        let lines = BugReporter.extensionProcessLines(
            running: [
                (pid: 101, path: "\(bundled)/Contents/MacOS/SystemWallpaperProvider"),
                (pid: 202, path: "\(elsewhere)/Contents/MacOS/SystemWallpaperProvider"),
                (pid: 303, path: "/System/Applications/Safari.app/Contents/MacOS/Safari"),
                (pid: 404, path: "/Applications/Loomscreen.app/Contents/Extensions/Other.appex/Contents/MacOS/Other"),
            ],
            bundledAppexPath: bundled,
            form: .english
        )
        #expect(lines.count == 2)
        #expect(lines.first?.contains("pid 101") == true)
        #expect(lines.first?.hasSuffix("bundled copy: yes") == true)
        #expect(lines.last?.contains("pid 202") == true)
        #expect(lines.last?.hasSuffix("bundled copy: no") == true)
        #expect(!lines.joined().contains("alice"), "an extension path leaked the user name")
    }

    @Test("No running copy is one explicit line")
    func noProcessesIsOneLine() {
        #expect(
            BugReporter.extensionProcessLines(running: [], bundledAppexPath: bundled, form: .english)
                == ["none running"]
        )
        #expect(
            BugReporter.extensionProcessLines(
                running: [(pid: 303, path: "/System/Applications/Safari.app/Contents/MacOS/Safari")],
                bundledAppexPath: bundled,
                form: .simplifiedChinese
            ) == ["没有在运行"]
        )
    }

    @Test("The section lands in both report forms")
    func sectionIsInTheReport() {
        let snapshot = SystemSnapshot(
            appVersion: "0.8.5", appBuild: "1", sku: .pro, macOSVersion: "27.0", macOSBuild: "27A1",
            hardwareModel: "Mac17,8", chip: "Apple M4 Pro", physicalMemoryGiB: 24, displays: [],
            activeWallpapers: [], bundleIdentifier: "com.loomscreen.pro", localeIdentifier: "en_US"
        )
        let english = BugReporter.formatMarkdown(
            snapshot: snapshot, recentLogLines: [], extensionProcessLines: ["none running"], form: .english
        )
        #expect(english.contains("**System wallpaper extension processes**"))
        #expect(english.contains("none running"))
        let chinese = BugReporter.formatMarkdown(
            snapshot: snapshot, recentLogLines: [], extensionProcessLines: ["没有在运行"], form: .simplifiedChinese
        )
        #expect(chinese.contains("**系统壁纸扩展进程**"))
        #expect(chinese.contains("没有在运行"))
    }
}
