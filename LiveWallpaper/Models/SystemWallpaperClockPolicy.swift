import Foundation

/// Identify removable widgets, never arbitrary uses of time (animation, weather, or music).
enum SystemWallpaperClockPolicy {
    static func isWidgetName(_ name: String) -> Bool {
        let key = name.lowercased().filter(\.isLetter)
        return ["时钟", "時鐘", "时间", "時間", "日期", "日历", "日曆", "時計", "カレンダー", "日付", "reloj", "calendario", "fecha"].contains(key)
            || key.range(of: "^(show|hide|enable|display)?(clock|calendar|datetime|dateandtime|date|time|day|weekday)(top|bottom|left|right|text|widget|container|group|display|enabled|visible)?$", options: .regularExpression) != nil
            || ["hourhand", "minutehand", "secondhand", "clockface", "digitalclock", "analogclock"].contains(key)
    }

    static func visibilityOverrides(projectData: Data?) -> [String: Bool] {
        guard let projectData,
              let project = (try? JSONSerialization.jsonObject(with: projectData)) as? [String: Any],
              let properties = (project["general"] as? [String: Any])?["properties"] as? [String: [String: Any]] else { return [:] }
        var result: [String: Bool] = [:]
        for (key, property) in properties where property["type"] as? String == "bool" {
            let label = property["text"] as? String ?? ""
            guard isWidgetName(key) || isWidgetName(label) else { continue }
            result[key] = key.lowercased().hasPrefix("hide") || label.lowercased().hasPrefix("hide")
        }
        return result
    }

    static func hiddenObjectIDs(sceneData: Data, projectData: Data?) -> Set<String> {
        guard let scene = (try? JSONSerialization.jsonObject(with: sceneData)) as? [String: Any],
              let objects = scene["objects"] as? [[String: Any]] else { return [] }
        let controls = Set(visibilityOverrides(projectData: projectData).keys)
        func identifier(_ value: Any?) -> String? {
            if let string = value as? String {
                return string
            }
            return (value as? NSNumber)?.stringValue
        }
        var hidden: Set<String> = []
        var parents: [String: String] = [:]
        for object in objects {
            guard let id = identifier(object["id"]) else { continue }
            parents[id] = identifier(object["parent"])
            let visible = object["visible"] as? [String: Any]
            let control = visible?["user"] as? String
            let text = object["text"] as? [String: Any]
            let script = text?["script"] as? String ?? ""
            let dateText = script.range(of: #"\.(get(UTC)?(Hours|Minutes|Seconds|Day|Date|Month|FullYear)|toLocale(Time|Date)String)\s*\(|Intl\.DateTimeFormat"#, options: .regularExpression) != nil
            if isWidgetName(object["name"] as? String ?? "") || dateText || control.map(controls.contains) == true {
                hidden.insert(id)
            }
        }
        // Include descendants so grouped image, text, and particle passes all disappear together.
        var previousCount = -1
        while previousCount != hidden.count {
            previousCount = hidden.count
            for (child, parent) in parents where hidden.contains(parent) {
                hidden.insert(child)
            }
        }
        return hidden
    }

    /// Runs only in the disposable web-export session. Keep late-created/replaced widgets hidden.
    static let webScript = #"""
    (() => {
        if (window.__lwClockHiding) return;
        window.__lwClockHiding = true;
        const name = /^(?:show|hide|enable|display)?(?:clock|calendar|datetime|dateandtime|date|time|day|weekday)(?:top|bottom|left|right|text|widget|container|group|display|enabled|visible)?$/i;
        const translated = ['时钟', '時鐘', '时间', '時間', '日期', '日历', '日曆', '時計', 'カレンダー', '日付', 'reloj', 'calendario', 'fecha'];
        const label = value => translated.includes(String(value || '').trim()) || name.test(String(value || '').replace(/[^a-z]/gi, ''));
        function hide(element) {
            element.setAttribute('data-loomscreen-clock-hidden', '');
            if (element.style.getPropertyValue('visibility') !== 'hidden' || element.style.getPropertyPriority('visibility') !== 'important') {
                element.style.setProperty('visibility', 'hidden', 'important');
            }
        }
        const style = document.createElement('style');
        style.textContent = '[data-loomscreen-clock-hidden] { visibility: hidden !important; opacity: 0 !important; pointer-events: none !important; }';
        document.head.appendChild(style);
        function visit(root) {
            if (!root) return;
            const elements = root.nodeType === 1 ? [root, ...root.querySelectorAll('*')] : [];
            for (const element of elements) {
                if (['HTML', 'BODY', 'HEAD', 'SCRIPT', 'STYLE', 'MAIN'].includes(element.tagName)) continue;
                const named = [element.id, ...element.classList, element.getAttribute('data-widget'), element.getAttribute('aria-label')].some(label);
                const text = element.childElementCount === 0 ? element.textContent.trim() : '';
                const time = /^(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?:\s*[AP]M)?$/i.test(text);
                const date = /^(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}|(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday))$/i.test(text);
                const media = element.closest('[id*=player i],[class*=player i],[id*=music i],[class*=music i],[id*=duration i],[class*=duration i],[id*=countdown i],[class*=countdown i]');
                if (named || (!media && (time || date || element.tagName === 'TIME'))) hide(element);
            }
        }
        visit(document.body);
        new MutationObserver(records => {
            for (const record of records) {
                for (const node of record.addedNodes) visit(node);
                if (record.type === 'characterData') visit(record.target.parentElement);
                if (record.type === 'attributes') {
                    if (record.attributeName !== 'style') visit(record.target);
                    else if (record.target.hasAttribute('data-loomscreen-clock-hidden')) hide(record.target);
                }
            }
        }).observe(document.body, {subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['id', 'class', 'aria-label', 'data-widget', 'style']});
    })();
    """#
}
