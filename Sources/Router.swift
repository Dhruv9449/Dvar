import AppKit

enum Log {
    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/chrome-router.log")
    }

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let fm = FileManager.default
        // Keep the log small: start over once it passes 1 MB.
        if let size = (try? fm.attributesOfItem(atPath: path.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: path)
        }
        if let h = try? FileHandle(forWritingTo: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: path)
        }
    }
}

enum Router {
    /// Decides and opens. Never throws: any failure falls back to opening the URL
    /// in the browser without a profile, so a click is never silently dropped.
    static func route(_ url: URL, source: SourceApp?, completion: @escaping (String) -> Void = { _ in }) {
        var notes: [String] = []
        let config: Config
        do {
            config = try Config.load()
        } catch {
            notes.append("\(error)")
            config = Config()
        }
        let browser = (try? Browser.from(config)) ?? (try! Browser.from(Config()))

        let decision = Matcher.decide(config, url: url, source: source) { notes.append($0) }
        let dir = decision.profile.flatMap { browser.resolveDirectory($0).directory }
        if let p = decision.profile, dir == nil {
            var why = "not found"
            do { _ = try browser.profiles() } catch { why = "unresolved: \(error)" }
            notes.append("profile \"\(p)\" \(why); opened without a profile")
        }
        let via = decision.ruleIndex.map { "rule #\($0 + 1)" } ?? "default"

        browser.open(url, profileDirectory: dir) { error in
            var line = "\(url.absoluteString) from=\(source?.label ?? "-") -> \(dir ?? "(browser default)") via \(via)"
            if let error { line += " ERROR \(error.localizedDescription)" }
            if !notes.isEmpty { line += " [\(notes.joined(separator: "; "))]" }
            Log.write(line)
            completion(line)
        }
    }
}

/// Background (LSUIElement) app that receives http/https links once set as the
/// default browser. Stays running so subsequent clicks are instant. Opening the
/// app yourself (Finder, Spotlight, `chrome-router ui`) shows the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsWindowController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // false when macOS launched us to open a link or file.
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefaultLaunch { settings.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s) else { return }
        var source: SourceApp?
        if let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value,
           let app = NSRunningApplication(processIdentifier: pid) {
            source = SourceApp(name: app.localizedName, bundleID: app.bundleIdentifier)
        }
        Router.route(url, source: source)
    }

    /// Local .html files opened with the default browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Router.route(url, source: nil) }
    }
}

@MainActor
func runApp() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}
