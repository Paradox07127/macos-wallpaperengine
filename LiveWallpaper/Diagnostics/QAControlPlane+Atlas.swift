#if DEBUG
import AppKit
import LiveWallpaperCore
import SwiftUI

/// UI Atlas tools: put the main window into a named state, open what a click would open, and say which windows to capture.
@MainActor
extension QAControlPlane {
    private static let pages: [String: EditDeskRouter.Page] = [
        "home": .home, "library": .library, "schemes": .schemes,
        "systemWallpaper": .systemWallpaper, "workshop": .workshop, "settings": .settings,
    ]

    func uiNavigate(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["page", "settings", "anchor", "displayID", "section"])
        guard let router else { throw QAError.message("Open the main window first") }
        if let raw = arguments["displayID"] {
            let id = try CGDirectDisplayID(QALibraryCatalog.integer(raw, key: "displayID", range: 0 ... Int(UInt32.max)))
            guard screenManager?.screens.contains(where: { $0.id == id }) == true else { throw QAError.message("Unknown displayID \(id)") }
            let section: DetailSection? = switch try QALibraryCatalog.optionalString(arguments["section"], key: "section") {
            case nil: nil
            case "wallpaper": .wallpaper
            case "overlay": .overlay
            case let other?: throw QAError.message("Rejected section \(other): use wallpaper, overlay")
            }
            router.showDetail(id, section: section)
        } else {
            guard let raw = try QALibraryCatalog.optionalString(arguments["page"], key: "page"), let page = Self.pages[raw] else {
                throw QAError.message("Pass displayID, or page: \(Self.pages.keys.sorted().joined(separator: ", "))")
            }
            if page == .settings {
                let destination = try QALibraryCatalog.optionalString(arguments["settings"], key: "settings").map { raw in
                    guard let value = SettingsNavigation(rawValue: raw) else {
                        throw QAError.message("Rejected settings \(raw): use \(SettingsNavigation.allCases.map(\.rawValue).joined(separator: ", "))")
                    }
                    return value
                } ?? .general
                let anchor = try QALibraryCatalog.optionalString(arguments["anchor"], key: "anchor").map { raw in
                    guard let value = SettingsSearchAnchor(rawValue: raw) else { throw QAError.message("Unknown anchor \(raw)") }
                    return value
                }
                router.closeDetail()
                router.openSettings(destination, anchor: anchor)
            } else {
                router.closeDetail()
                router.select(page)
            }
        }
        return Self.routeState(router)
    }

    func uiRoute() throws -> Any {
        guard let router else { throw QAError.message("Open the main window first") }
        return Self.routeState(router)
    }

    private static func routeState(_ router: EditDeskRouter) -> [String: Any] {
        [
            "page": pages.first(where: { $0.value == router.page })?.key ?? "unknown",
            "detailDisplayID": router.detailDisplayID ?? NSNull(),
            "settings": router.settingsSelection?.rawValue ?? NSNull(),
            "libraryTarget": router.libraryTarget ?? NSNull(),
            "settingsDestinations": SettingsNavigation.allCases.map(\.rawValue),
        ]
    }

    // MARK: - Windows

    /// Every on-screen window this process owns, front to back, in global points with a top-left origin.
    func uiWindows() -> Any {
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let appWindows = Dictionary(NSApp.windows.map { ($0.windowNumber, $0) }, uniquingKeysWith: { first, _ in first })
        let mainNumber = Self.mainWindow()?.windowNumber
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = info.compactMap { entry -> [String: Any]? in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue else { return nil }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            var item: [String: Any] = [
                "number": number, "layer": layer,
                "bounds": entry[kCGWindowBounds as String] ?? [:],
                "alpha": entry[kCGWindowAlpha as String] ?? 1,
            ]
            let window = appWindows[number]
            let className = window.map { String(describing: type(of: $0)) } ?? ""
            if let window {
                item["class"] = className
                item["title"] = window.title
                item["identifier"] = window.identifier?.rawValue ?? NSNull()
                item["isKey"] = window.isKeyWindow
                item["sheetParent"] = window.sheetParent?.windowNumber ?? NSNull()
                item["parent"] = window.parent?.windowNumber ?? NSNull()
            }
            let role = if number == mainNumber {
                "main"
            } else if className.contains("StatusBarWindow") {
                "statusItem"
            } else if window?.sheetParent != nil {
                "sheet"
            } else if className.contains("Popover") {
                "popover"
            } else if layer == menuLayer {
                "menu"
            } else if window is NSPanel {
                "panel"
            } else {
                "window"
            }
            item["role"] = role
            return item
        }
        let keyNumber: Any = NSApp.keyWindow?.windowNumber ?? NSNull()
        let mainValue: Any = mainNumber ?? NSNull()
        return ["appActive": NSApp.isActive, "keyWindowNumber": keyNumber, "mainWindowNumber": mainValue, "windows": windows]
    }

    func uiActivate() -> Any {
        NSApp.activate()
        Self.mainWindow()?.makeKeyAndOrderFront(nil)
        // A focused text field swallows the next synthesized click on a menu button.
        Self.mainWindow()?.makeFirstResponder(nil)
        let keyNumber: Any = NSApp.keyWindow?.windowNumber ?? NSNull()
        return ["appActive": NSApp.isActive, "keyWindowNumber": keyNumber]
    }

    /// Resizes the main window's content, keeping its top-left corner; never below the window's minimum.
    func uiWindowSize(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["width", "height"])
        guard let window = Self.mainWindow() else { throw QAError.message("Open the main window first") }
        var content = window.contentRect(forFrameRect: window.frame).size
        if let raw = arguments["width"] {
            content.width = try max(CGFloat(QALibraryCatalog.integer(raw, key: "width", range: 1 ... 10000)), window.contentMinSize.width)
        }
        if let raw = arguments["height"] {
            content.height = try max(CGFloat(QALibraryCatalog.integer(raw, key: "height", range: 1 ... 10000)), window.contentMinSize.height)
        }
        if !arguments.isEmpty {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
        let size = window.contentRect(forFrameRect: window.frame).size
        return [
            "contentSize": ["width": size.width, "height": size.height],
            "minimumContentSize": ["width": window.contentMinSize.width, "height": window.contentMinSize.height],
            "screenVisibleSize": ["width": window.screen?.visibleFrame.width ?? 0, "height": window.screen?.visibleFrame.height ?? 0],
        ]
    }

    /// Not persisted: `stored` puts back the user's Appearance preference.
    func uiAppearance(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["mode"])
        switch try QALibraryCatalog.optionalString(arguments["mode"], key: "mode") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        case "stored": AppAppearance.stored(in: .appScoped()).apply()
        default: throw QAError.message("Rejected mode: use light, dark, system, stored")
        }
        return ["effective": NSApp.effectiveAppearance.name.rawValue]
    }

    // MARK: - Controls and clicks

    private static func targetWindow(_ arguments: [String: Any]) throws -> NSWindow {
        if let raw = arguments["window"] {
            let number = try QALibraryCatalog.integer(raw, key: "window", range: 0 ... Int(Int32.max))
            guard let window = NSApp.windows.first(where: { $0.windowNumber == number }) else { throw QAError.message("No app window \(number)") }
            return window
        }
        guard let window = NSApp.keyWindow ?? mainWindow() else { throw QAError.message("No key window") }
        return window
    }

    /// Components tagged with `atlasRole` that are on screen now, in window points (top-left origin).
    /// Frames are read at call time, so they follow scrolling and layout.
    func uiControls(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["window", "role"])
        guard AtlasMarker.isEnabled else { throw QAError.message("Launch the app with LOOMSCREEN_ATLAS=1 to tag components") }
        let only = try arguments["window"].map { try QALibraryCatalog.integer($0, key: "window", range: 0 ... Int(Int32.max)) }
        let role = try QALibraryCatalog.optionalString(arguments["role"], key: "role")
        let controls: [[String: Any]] = AtlasMarker.views.allObjects.compactMap { view in
            guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
                  only == nil || window.windowNumber == only, role == nil || view.role == role else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            // A hosted view's own visibleRect spans the window, so clip by the scroll views above it instead.
            var visible = frame.intersection(window.contentView?.convert(window.contentView?.bounds ?? .zero, to: nil) ?? frame)
            var container = view.superview
            while let current = container {
                if current is NSClipView {
                    visible = visible.intersection(current.convert(current.bounds, to: nil))
                }
                container = current.superview
            }
            guard !visible.isEmpty else { return nil }
            let height = window.frame.height
            var entry: [String: Any] = [
                "role": view.role, "window": window.windowNumber,
                "frame": ["x": frame.minX, "y": height - frame.maxY, "width": frame.width, "height": frame.height],
                "visible": ["x": visible.minX, "y": height - visible.maxY, "width": visible.width, "height": visible.height],
            ]
            if let label = view.label {
                entry["label"] = label
            }
            entry["alpha"] = Self.effectiveAlpha(view)
            return entry
        }
        var stage: [[String: Any]] = []
        for window in NSApp.windows where window.isVisible && (only == nil || window.windowNumber == only) {
            var pending = window.contentView.map { [$0] } ?? []
            while let view = pending.popLast() {
                pending += view.subviews
                guard let stageView = view as? EditDeskStageView, !stageView.isHiddenOrHasHiddenAncestor else { continue }
                let bounds = stageView.convert(stageView.bounds, to: nil)
                let height = window.frame.height
                for item in stageView.debugAtlasItems where role == nil || item.role == role {
                    let visible = item.frame.intersection(bounds)
                    guard !visible.isEmpty else { continue }
                    stage.append([
                        "role": item.role, "label": item.label, "window": window.windowNumber, "alpha": Self.effectiveAlpha(stageView),
                        "frame": ["x": item.frame.minX, "y": height - item.frame.maxY, "width": item.frame.width, "height": item.frame.height],
                        "visible": ["x": visible.minX, "y": height - visible.maxY, "width": visible.width, "height": visible.height],
                    ])
                }
            }
        }
        return ["controls": controls + stage]
    }

    private static func effectiveAlpha(_ view: NSView) -> Double {
        var alpha = 1.0
        var ancestor: NSView? = view
        while let current = ancestor {
            alpha *= current.alphaValue * Double(current.layer?.opacity ?? 1)
            ancestor = current.superview
        }
        return alpha
    }

    // MARK: - Page guides

    func uiGuide(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["action", "context", "page"])
        guard let guide = pageGuide else { throw QAError.message("No page guide; open the main window") }
        switch try QALibraryCatalog.optionalString(arguments["action"], key: "action") ?? "state" {
        case "state":
            break
        case "start":
            let name = try QALibraryCatalog.optionalString(arguments["context"], key: "context") ?? ""
            guard let context = PageGuideContext.allCases.first(where: { String(describing: $0) == name }) else {
                throw QAError.message("Rejected context \(name): use \(PageGuideContext.allCases.map { String(describing: $0) }.joined(separator: ", "))")
            }
            guide.start(context, router: router)
        case "tour":
            let name = try QALibraryCatalog.optionalString(arguments["page"], key: "page") ?? ""
            guard let page = OnboardingProgress.Page.allCases.first(where: { String(describing: $0) == name }) else {
                throw QAError.message("Rejected page \(name): use \(OnboardingProgress.Page.allCases.map { String(describing: $0) }.joined(separator: ", "))")
            }
            guard let startTour else { throw QAError.message("No onboarding tour; open the main window") }
            startTour(page)
        case "next": guide.next()
        case "back": guide.back()
        case "close": guide.close()
        case let other:
            throw QAError.message("Rejected action \(other): use state, start, tour, next, back, close")
        }
        var state: [String: Any] = ["active": guide.context != nil]
        if let context = guide.context {
            state["context"] = String(describing: context)
            state["index"] = guide.index
            state["steps"] = guide.steps.count
            state["stepNumber"] = guide.stepNumber
            state["stepCount"] = guide.stepCount
            state["isLastStep"] = guide.isLastStep
        }
        if let page = guide.tourPage {
            state["tourPage"] = String(describing: page)
        }
        return state
    }

    /// Posts a mouse click at window points (top-left origin) through the app's event queue, so it is handled
    /// after this reply like a real click: a menu or sheet it opens runs its own loop without holding the reply.
    func uiClick(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["window", "x", "y", "button", "count"])
        let window = try Self.targetWindow(arguments)
        guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue else {
            throw QAError.message("Pass x and y in window points, top-left origin")
        }
        let right = switch try QALibraryCatalog.optionalString(arguments["button"], key: "button") ?? "left" {
        case "left": false
        case "right": true
        case let other: throw QAError.message("Rejected button \(other): use left, right")
        }
        let count = try arguments["count"].map { try QALibraryCatalog.integer($0, key: "count", range: 1 ... 2) } ?? 1
        let location = NSPoint(x: x, y: window.frame.height - y)
        let pair: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for click in 1 ... count {
            for type in pair {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: click,
                    pressure: type == pair[0] ? 1 : 0
                ) else { throw QAError.message("Could not make the mouse event") }
                NSApp.postEvent(event, atStart: false)
            }
        }
        return ["status": "posted", "window": window.windowNumber, "x": x, "y": y, "button": right ? "right" : "left", "count": count]
    }

    // MARK: - Menus, keys, scrolling, status item

    func installMenuTracking() {
        guard menuObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                nonisolated(unsafe) let menu = note.object as? NSMenu // queue: .main runs this block on the main thread; assumeIsolated traps otherwise.
                MainActor.assumeIsolated { QAControlPlane.shared.trackedMenu = menu }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
                nonisolated(unsafe) let menu = note.object as? NSMenu // queue: .main runs this block on the main thread; assumeIsolated traps otherwise.
                MainActor.assumeIsolated {
                    if QAControlPlane.shared.trackedMenu === menu {
                        QAControlPlane.shared.trackedMenu = nil
                    }
                }
            },
        ]
    }

    func uiMenu(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["action", "title"])
        switch try QALibraryCatalog.optionalString(arguments["action"], key: "action") ?? "current" {
        case "current":
            guard let menu = trackedMenu else { return ["tracking": false] }
            return ["tracking": true, "title": menu.title, "items": Self.describe(menu)]
        case "close":
            let menu = trackedMenu
            menu?.cancelTracking()
            return ["closed": menu != nil]
        case "main":
            return ["items": NSApp.mainMenu.map { Self.describe($0) } ?? []]
        case "pick", "pickMain":
            let isMain = arguments["action"] as? String == "pickMain"
            guard let root = isMain ? NSApp.mainMenu : trackedMenu else { throw QAError.message(isMain ? "No main menu" : "No menu is tracking") }
            let path = try QALibraryCatalog.optionalString(arguments["title"], key: "title") ?? ""
            root.update()
            guard let (menu, index) = Self.item(path.components(separatedBy: " > "), in: root), menu.items[index].isEnabled else {
                throw QAError.message("No enabled item \(path)")
            }
            if !isMain {
                root.cancelTracking()
            }
            // After this reply: the action can open a sheet or panel that runs its own loop.
            DispatchQueue.main.async { menu.performActionForItem(at: index) }
            return ["picked": path]
        case let other:
            throw QAError.message("Rejected action \(other): use current, close, main, pick, pickMain")
        }
    }

    /// `path` = item titles from the top level down; returns the menu holding the last one.
    private static func item(_ path: [String], in menu: NSMenu) -> (NSMenu, Int)? {
        guard let title = path.first, let index = menu.items.firstIndex(where: { !$0.isSeparatorItem && $0.title == title }) else { return nil }
        if path.count == 1 {
            return (menu, index)
        }
        guard let submenu = menu.items[index].submenu else { return nil }
        submenu.update()
        return item(Array(path.dropFirst()), in: submenu)
    }

    private static func describe(_ menu: NSMenu, depth: Int = 0) -> [[String: Any]] {
        menu.items.map { item in
            if item.isSeparatorItem {
                return ["separator": true]
            }
            var entry: [String: Any] = ["title": item.title]
            if item.isSectionHeader {
                entry["sectionHeader"] = true
            }
            if !item.isEnabled {
                entry["enabled"] = false
            }
            if item.isHidden {
                entry["hidden"] = true
            }
            if item.image != nil {
                entry["image"] = true
            }
            if item.state == .on {
                entry["state"] = "on"
            } else if item.state == .mixed {
                entry["state"] = "mixed"
            }
            if !item.keyEquivalent.isEmpty {
                let flags = item.keyEquivalentModifierMask
                let prefix = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                    .filter { flags.contains($0.0) }.map(\.1).joined()
                entry["key"] = prefix + item.keyEquivalent.uppercased()
            }
            if let submenu = item.submenu, depth < 4 {
                entry["submenu"] = describe(submenu, depth: depth + 1)
            }
            return entry
        }
    }

    /// Posted through the app's event queue, so the key window (or a tracking menu) handles it like a real key.
    func uiKey(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["key", "text", "window"])
        let keys: [String: (String, UInt16)] = [
            "escape": ("\u{1b}", 53), "return": ("\r", 36), "tab": ("\t", 48), "space": (" ", 49),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
        ]
        let presses: [(String, UInt16)]
        if let text = try QALibraryCatalog.optionalString(arguments["text"], key: "text") {
            presses = text.map { (String($0), 0) }
        } else if let name = try QALibraryCatalog.optionalString(arguments["key"], key: "key"), let press = keys[name] {
            presses = [press]
        } else {
            throw QAError.message("Pass text, or key: \(keys.keys.sorted().joined(separator: ", "))")
        }
        let windowNumber = try arguments["window"] == nil ? NSApp.keyWindow?.windowNumber ?? 0 : Self.targetWindow(arguments).windowNumber
        for (characters, code) in presses {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code
                ) else { throw QAError.message("Could not make the key event") }
                NSApp.postEvent(event, atStart: false)
            }
        }
        return ["status": "posted", "presses": presses.count, "window": windowNumber]
    }

    /// Lists the window's scroll views, largest first; with `index` and `to`/`page`, moves that one's clip view.
    func uiScroll(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["window", "index", "to", "page"])
        let window = try Self.targetWindow(arguments)
        var scrollViews: [NSScrollView] = []
        func collect(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let scrollView = view as? NSScrollView, let document = scrollView.documentView,
               document.frame.height > scrollView.contentView.bounds.height + 1 {
                scrollViews.append(scrollView)
            }
            view.subviews.forEach(collect)
        }
        window.contentView.map(collect)
        scrollViews.sort { $0.visibleRect.width * $0.visibleRect.height > $1.visibleRect.width * $1.visibleRect.height }
        func state(_ scrollView: NSScrollView) -> [String: Any] {
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            let clip = scrollView.contentView.bounds
            let document = scrollView.documentView?.frame.height ?? 0
            let offset = scrollView.documentView?.isFlipped == false ? document - clip.maxY : clip.minY
            return [
                "frame": ["x": frame.minX, "y": window.frame.height - frame.maxY, "width": frame.width, "height": frame.height],
                "documentHeight": document, "visibleHeight": clip.height, "offset": offset,
                "pages": Int((document / max(clip.height, 1)).rounded(.up)),
            ]
        }
        guard let rawIndex = arguments["index"] else {
            return ["window": window.windowNumber, "scrollViews": scrollViews.map(state)]
        }
        let index = try QALibraryCatalog.integer(rawIndex, key: "index", range: 0 ... 99)
        guard index < scrollViews.count else { throw QAError.message("index out of range (\(scrollViews.count) scroll views)") }
        let scrollView = scrollViews[index]
        let clip = scrollView.contentView
        let document = scrollView.documentView?.frame.height ?? 0
        let maxOffset = max(document - clip.bounds.height, 0)
        let offset: CGFloat = switch try QALibraryCatalog.optionalString(arguments["to"], key: "to") {
        case "top": 0
        case "bottom": maxOffset
        case nil: try min(CGFloat(arguments["page"].map { try QALibraryCatalog.integer($0, key: "page", range: 0 ... 999) } ?? 0) * clip.bounds.height, maxOffset)
        case let other?: throw QAError.message("Rejected to \(other): use top, bottom, or pass page")
        }
        let y = scrollView.documentView?.isFlipped == false ? maxOffset - offset : offset
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
        return state(scrollView)
    }

    func uiStatusItem() throws -> Any {
        guard let window = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBarWindow") }),
              let button = Self.firstSubview(NSStatusBarButton.self, in: window.contentView) else {
            throw QAError.message("No status item button")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            button.performClick(nil)
        }
        return ["status": "scheduled", "window": window.windowNumber, "onScreen": window.isOnActiveSpace && window.occlusionState.contains(.visible)]
    }

    private static var menuBarPanel: NSPanel?

    /// The menu bar panel's content hosted in a QA panel, for when the status item is not on screen (hidden by the
    /// notch or menu bar overflow) and cannot be clicked. Its buttons do nothing.
    func uiMenuBarPanel(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["action"])
        Self.menuBarPanel?.close()
        Self.menuBarPanel = nil
        if try QALibraryCatalog.optionalString(arguments["action"], key: "action") == "close" {
            return ["closed": true]
        }
        guard let screenManager else { throw QAError.message("No screen manager") }
        let content = MenuBarContent(openSettings: {}, openSettingsForScreen: { _ in }, openHome: {}, openSettingsAndAddWallpaper: { _ in })
            .environment(screenManager)
            .environment(\.featureCatalog, screenManager.featureCatalog)
            .appLanguageScoped(defaults: .appScoped())
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        let panel = NSPanel(contentRect: effect.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.contentView = effect
        if let main = Self.mainWindow() {
            panel.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX - size.width - 16, y: main.frame.maxY - 16))
        }
        panel.orderFrontRegardless()
        Self.menuBarPanel = panel
        return ["window": panel.windowNumber, "width": size.width, "height": size.height]
    }

    private static func firstSubview<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = firstSubview(type, in: subview) {
                return match
            }
        }
        return nil
    }

    static var atlasToolDescriptions: [[String: Any]] {
        let window: [String: Any] = ["type": "integer", "description": "App window number from ui.windows; default the key window"]
        func entry(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false]]
        }
        return [
            entry("ui.navigate", "Route the main window: page (home, library, schemes, systemWallpaper, workshop, settings) with optional settings destination and anchor, or displayID with optional section (wallpaper, overlay) for a display detail. Returns the router state read back.",
                  ["page": ["type": "string"], "settings": ["type": "string"], "anchor": ["type": "string"],
                   "displayID": ["type": "integer"], "section": ["type": "string"]]),
            entry("ui.route", "Read the main window's router state.", [:]),
            entry("ui.windows", "This process's on-screen windows front to back: number, layer, bounds (global, top-left origin), role (main, sheet, popover, menu, statusItem, panel, window), isKey.", [:]),
            entry("ui.activate", "Activate the app, front the main window and end text editing in it. Activation can be refused while another app is active; read appActive.", [:]),
            entry("ui.windowSize", "Resize the main window's content (points), keeping its top-left corner and minimum size; no arguments reads it.",
                  ["width": ["type": "integer"], "height": ["type": "integer"]]),
            entry("ui.appearance", "Set NSApp.appearance without saving it: light, dark, system, or stored (the user's preference).",
                  ["mode": ["type": "string", "enum": ["light", "dark", "system", "stored"]]]),
            entry("ui.controls", "Components tagged for the atlas (launch with LOOMSCREEN_ATLAS=1) that are visible now: role, label (symbol or code; absent when the component carries none), window, frame and visible rect in window points, top-left origin.",
                  ["window": window, "role": ["type": "string"]]),
            entry("ui.guide", "Drive the main window's page guide: state; start with context (overview, library, saved, systemWallpaper, workshop, settings, configuration, overlays, automation); tour with page (starts the onboarding tour there and records it as presented); next; back; close. Returns the guide state.",
                  ["action": ["type": "string", "enum": ["state", "start", "tour", "next", "back", "close"]],
                   "context": ["type": "string"], "page": ["type": "string"]]),
            entry("ui.click", "Post a mouse click at window points (top-left origin) through the app's event queue; it is handled after this reply.",
                  ["window": window, "x": ["type": "number"], "y": ["type": "number"],
                   "button": ["type": "string", "enum": ["left", "right"]], "count": ["type": "integer"]]),
            entry("ui.menu", "current: items of the menu being tracked (titles, sections, shortcuts, submenus); close: cancel its tracking; main: the main menu bar; pick / pickMain: close the tracked menu (or use the main menu) and perform the item at title, a path like \"File > Import\".",
                  ["action": ["type": "string", "enum": ["current", "close", "main", "pick", "pickMain"]], "title": ["type": "string"]]),
            entry("ui.key", "Post a key press (escape, return, tab, space, arrows), or type text one character at a time, through the app's event queue to the key window or a given window.",
                  ["key": ["type": "string"], "text": ["type": "string"], "window": window]),
            entry("ui.scroll", "List a window's scroll views (largest first) with document and visible heights; with index and to (top, bottom) or page, scroll that one.",
                  ["window": window, "index": ["type": "integer"], "to": ["type": "string"], "page": ["type": "integer"]]),
            entry("ui.statusItem", "Click the menu bar status item after replying, which opens or closes its panel. onScreen false: the item is hidden and the click opens nothing; use ui.menuBarPanel.", [:]),
            entry("ui.menuBarPanel", "Host the menu bar panel's content in a QA panel at the main window's top-right corner (its buttons do nothing); action close removes it.",
                  ["action": ["type": "string", "enum": ["open", "close"]]]),
        ]
    }
}
#endif
