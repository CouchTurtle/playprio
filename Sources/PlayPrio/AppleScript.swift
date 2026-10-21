import AppKit

enum ScriptError: Error {
    /// The browser's View → Developer → "Allow JavaScript from Apple Events" is off.
    case javaScriptDisabled(app: String)
    /// The user denied PlayPrio control of that app (Privacy & Security → Automation).
    case notAuthorized(app: String)
    case failed(String)
}

enum AppleScript {
    /// Apple events wait up to two minutes by default; a busy tab or a hung app must not
    /// hold up the media keys that long.
    private static let timeoutSeconds = 3

    /// Not safe to call concurrently: the app runs every script on one serial queue
    /// (`Store`), the command-line mode on the main thread.
    static func run(_ source: String, app: String) throws -> String {
        try runForDescriptor(source, app: app).stringValue ?? ""
    }

    static func runForDescriptor(_ source: String, app: String) throws -> NSAppleEventDescriptor {
        let wrapped = "with timeout of \(timeoutSeconds) seconds\n\(source)\nend timeout"
        guard let script = NSAppleScript(source: wrapped) else { throw ScriptError.failed("compile") }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let number = info[NSAppleScript.errorNumber] as? Int ?? 0
            let message = info[NSAppleScript.errorMessage] as? String ?? "unknown error"
            switch number {
            case 12: throw ScriptError.javaScriptDisabled(app: app)
            case -1743: throw ScriptError.notAuthorized(app: app)
            default: throw ScriptError.failed("\(app): \(message) (\(number))")
            }
        }
        return result
    }

    /// Escapes text for use inside an AppleScript "double-quoted" literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum MediaFile {
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "opus",
                                          "mp4", "m4v", "mov", "webm"]
}

/// A Chromium browser with Chrome's AppleScript dictionary ("execute javascript").
struct Chromium: Hashable {
    let bundleID: String
    let name: String

    static let chrome = Chromium(bundleID: "com.google.Chrome", name: "Google Chrome")
    static let all = [
        chrome,
        Chromium(bundleID: "com.brave.Browser", name: "Brave Browser"),
        Chromium(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge"),
        Chromium(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi"),
    ]

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Runs `js` in every tab (PWA windows included) whose URL starts with one of `prefixes`
    /// (any tab if empty), or only in those of them in `tabIDs`. Empty answers are left out.
    func runJS(_ js: String, inTabsMatching prefixes: [String] = [], tabIDs: Set<String>? = nil) throws -> [(tabID: String, value: String)] {
        var test = prefixes.isEmpty ? "true" : "(\(Self.startsWith(prefixes)))"
        if let tabIDs { test += " and tid is in {\(tabIDs.map(AppleScript.quoted).joined(separator: ", "))}" }
        return try execute(js, inTabsWhere: test)
    }

    /// Runs `js` in the tabs that might be playing: the `known` ones and, when `discover` is
    /// set, each window's active tab and tabs showing a media file. Scanning every tab is
    /// far too slow (background tabs take ~70 ms each), and the browser can't say which tab
    /// is audible.
    func runJSInLikelyMediaTabs(_ js: String, known: Set<String>, discover: Bool,
                                excluding excluded: [String]) throws -> [(tabID: String, value: String)] {
        var test = "tid is in {\(known.map(AppleScript.quoted).joined(separator: ", "))}"
        if discover {
            let mediaURL = [#"u starts with "file:""#] + MediaFile.extensions.sorted().map { "u ends with \(AppleScript.quoted("." + $0))" }
            test += " or tid is in activeIDs or " + mediaURL.joined(separator: " or ")
        }
        if !excluded.isEmpty { test = "(\(test)) and not (\(Self.startsWith(excluded)))" }
        let collectActive = """
            set activeList to id of active tab of every window
            repeat with i from 1 to count of activeList
                set end of activeIDs to (item i of activeList) as text
            end repeat
            """
        return try execute(js, inTabsWhere: test, preamble: discover ? collectActive : "")
    }

    /// Selects the tab, raises its window (a PWA window too) and activates the browser.
    func focusTab(id: String) throws {
        let source = """
        tell application id "\(bundleID)"
            repeat with w in windows
                set tabIDs to id of every tab of w
                repeat with ti from 1 to count of tabIDs
                    if ((item ti of tabIDs) as text) is \(AppleScript.quoted(id)) then
                        set active tab index of w to ti
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        _ = try AppleScript.run(source, app: name)
    }

    private static func startsWith(_ prefixes: [String]) -> String {
        prefixes.map { "u starts with \(AppleScript.quoted($0))" }.joined(separator: " or ")
    }

    /// Runs `js` in each tab for which the AppleScript condition `test` holds (it can use
    /// `u`, the URL, `tid`, the tab id as text, and `activeIDs`). Returns (tab id, result);
    /// tabs where the script returns nothing are left out.
    ///
    /// URLs and ids come in bulk Apple Events and are matched locally (walking tabs one by
    /// one costs an event each); tabs are then addressed by id, so windows moving in
    /// between can't redirect the script. Results come back as an AppleScript list, so a
    /// page can't forge entries by returning text with line breaks.
    private func execute(_ js: String, inTabsWhere test: String, preamble: String = "") throws -> [(tabID: String, value: String)] {
        let source = """
        set out to {}
        tell application id "\(bundleID)"
            set activeIDs to {}
            \(preamble)
            set winIDs to id of every window
            set allURLs to URL of every tab of every window
            set allIDs to id of every tab of every window
            repeat with wi from 1 to count of allURLs
                set tabURLs to item wi of allURLs
                repeat with ti from 1 to count of tabURLs
                    set u to item ti of tabURLs
                    set tid to (item ti of item wi of allIDs) as text
                    if \(test) then
                        try
                            set r to execute (tab id (item ti of item wi of allIDs) of window id (item wi of winIDs)) javascript \(AppleScript.quoted(js))
                        on error errMsg number errNum
                            if errNum is 12 then error errMsg number errNum
                            set r to ""
                        end try
                        if r is missing value then set r to ""
                        if r is not "" then set end of out to {tid, r as text}
                    end if
                end repeat
            end repeat
        end tell
        return out
        """
        let list = try AppleScript.runForDescriptor(source, app: name)
        guard list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { index in
            guard let pair = list.atIndex(index), let tabID = pair.atIndex(1)?.stringValue,
                  let value = pair.atIndex(2)?.stringValue else { return nil }
            return (tabID, value)
        }
    }
}
