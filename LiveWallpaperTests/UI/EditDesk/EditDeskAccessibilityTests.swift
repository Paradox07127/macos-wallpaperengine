#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// WP 6.4 §4: what VoiceOver is handed by the views this milestone added. Read off a live AX tree
/// where the view can be hosted offscreen, and off the source where it cannot — the Steam wizard
/// needs two services, and focus order and the rotor have no offscreen representation at all.
@MainActor
@Suite("Edit Desk accessibility", .serialized)
struct EditDeskAccessibilityTests {
    struct AXNode {
        let role: String
        let label: String
        let value: String
        let actions: [String]
    }

    private static func nodes(under root: any NSAccessibilityProtocol, depth: Int = 0) -> [AXNode] {
        guard depth < 12, let children = root.accessibilityChildren() else { return [] }
        return children.flatMap { child -> [AXNode] in
            guard let element = child as? any NSAccessibilityProtocol else { return [] }
            let node = AXNode(
                role: element.accessibilityRole()?.rawValue ?? "",
                label: element.accessibilityLabel() ?? "",
                value: element.accessibilityValue() as? String ?? "",
                actions: element.accessibilityCustomActions()?.map(\.name) ?? []
            )
            return [node] + nodes(under: element, depth: depth + 1)
        }
    }

    /// SwiftUI only builds an accessibility tree for a view in a window, so the host goes into one
    /// parked far off every display, exactly as `ProbeRenderer` does for the fidelity images.
    private func hostedNodes(size: CGSize, @ViewBuilder _ view: () -> some View) async -> [AXNode] {
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .standard) {
            view().frame(width: size.width, height: size.height)
        })
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        var found = Self.nodes(under: host)
        if found.isEmpty {
            found = Self.nodes(under: window)
        }
        window.orderOut(nil)
        window.contentView = nil
        return found
    }

    private func progress() throws -> OnboardingProgress {
        let defaults = try #require(UserDefaults(suiteName: "wp64.accessibility.\(UUID().uuidString)"))
        return OnboardingProgress(defaults: defaults, legacyDefaults: defaults, workshopAvailable: true)
    }

    private func label(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .appLanguage)
    }

    /// Why the SwiftUI half of this file is a source contract: the AX bridge is only built when an
    /// assistive client has attached, so an offscreen host reports one empty `AXGroup` whatever the
    /// view put on it. Walking the real tree is on the 实机 list, not skipped silently.
    @Test("SwiftUI hands an offscreen host no accessibility tree to read")
    func swiftUITreeIsNotReadableOffscreen() async throws {
        let progress = try progress()
        let nodes = await hostedNodes(size: StageGeometry.designWindow) {
            OnboardingCard(page: .home) { _ in }
                .environment(progress)
        }
        print("AX card = \(nodes.map { "\($0.role)|\($0.label)" })")
        let spoken = nodes.map(\.label).filter { !$0.isEmpty }
        #expect(
            spoken.isEmpty,
            Comment(rawValue: "the bridge started reporting labels — turn the source contracts below into tree walks: \(spoken)")
        )
    }

    /// The accessibility the two onboarding views carry, read off the source. Each expectation is
    /// one line of the 实机 walk: what VoiceOver should say, and what it must not repeat.
    @Test("The onboarding card and capsule name themselves and hide their decoration")
    func onboardingContracts() throws {
        let card = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCard.swift")
        // The step line and the page title read as one heading, so the rotor can land on it.
        #expect(card.contains("accessibilityElement(children: .combine)"))
        #expect(card.contains("accessibilityAddTraits(.isHeader)"))
        // The glyph is decoration; the message beside it already says what the step is.
        let icon = try #require(card.range(of: "Image(systemName: content.icon)"))
        let hidden = try #require(card.range(of: "accessibilityHidden(true)"))
        #expect(icon.lowerBound < hidden.lowerBound, "the card's icon would be read out as a symbol name")
        // Both action buttons and Skip are real `Button`s with a spoken label.
        #expect(card.contains("accessibilityLabel(Text(title))"))
        #expect(card.contains(#"accessibilityLabel(Text("Skip this step"))"#), "\"Skip\" alone does not say what it skips")

        let capsule = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCapsule.swift")
        #expect(capsule.contains("accessibilityElement(children: .ignore)"), "each dot would become its own element")
        #expect(capsule.contains(#"accessibilityLabel(Text("Get Started"))"#))
        #expect(capsule.contains("accessibilityValue(Text(verbatim: OnboardingCardContent.stepText("))
        // The value is the progress itself, so the pill answers "how far in am I".
        #expect(OnboardingCardContent.stepText(step: 2, total: 4) == "STEP 2 / 4")
    }

    /// 6.1c's two entry points are drawn into a CALayer, so the display element carries them as
    /// custom actions; that is the whole keyboard and VoiceOver path to them.
    @Test("An empty display carries Choose File and Paste URL as custom actions, and presses open it")
    func emptyDisplayActions() async throws {
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [
            StageDisplay(
                id: 1, fingerprint: "a", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                isBuiltin: false, name: "External", badgeText: "EXTERNAL", statusText: "Main", cover: nil, state: .empty
            ),
            StageDisplay(
                id: 2, fingerprint: "b", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                isBuiltin: false, name: "Second", badgeText: "EXTERNAL", statusText: "", cover: nil, state: .ok
            ),
        ]
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        var events = model.events.makeAsyncIterator()
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let empty = try #require(children.first { $0.accessibilityLabel() == "External Main" })
        let filled = try #require(children.first { $0.accessibilityLabel() == "Second " })
        let actions = try #require(empty.accessibilityCustomActions())
        #expect(actions.map(\.name) == [label("Choose File…"), label("Paste URL")])
        // A display that already has a wallpaper must not offer them.
        #expect(filled.accessibilityCustomActions()?.isEmpty == true)
        try #require(actions[0].handler?() == true)
        #expect(await events.next() == .emptyActionTapped(1, .chooseFile))
        try #require(actions[1].handler?() == true)
        #expect(await events.next() == .emptyActionTapped(1, .pasteURL))
        // Return / VoiceOver press still opens the display itself.
        #expect(empty.accessibilityPerformPress())
        #expect(await events.next() == .displayTapped(1))
    }

    /// The three views that cannot be hosted offscreen: the wizard needs `SteamCMDDoctorService`
    /// and `WorkshopSetupController`, and both Workshop views are outside this package.
    @Test("The wizard's status rows, the modal's Steam button and the browse card name themselves")
    func sourceContracts() throws {
        let wizard = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Onboarding/SteamWizard.swift")
        #expect(
            wizard.contains("accessibilityElement(children: .combine)"),
            "each status row must read as one element, not a title, a glyph and a detail"
        )
        let modal = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModal.swift")
        let arrow = try #require(modal.range(of: #"Text(verbatim: "↗")"#))
        let labelled = try #require(modal.range(of: #"accessibilityLabel(Text("Open in Steam"))"#))
        #expect(arrow.lowerBound < labelled.lowerBound, "the glyph button would read as its arrow")
        let card = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseCard.swift")
        #expect(card.contains("accessibilityElement(children: .ignore)"), "the card's badges would each be read out")
        #expect(card.contains("accessibilityLabel(Text(accessibilityLabelText))"))
        #expect(card.contains("stars"), "the card's label drops the rating")
    }
}
#endif
