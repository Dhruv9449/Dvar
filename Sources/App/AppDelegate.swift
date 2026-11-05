import AppKit

/// Dvar.app: a background app (no Dock icon) registered for http and https. Links
/// arrive as Apple Events; launching the app yourself shows the settings window.
/// It keeps running after the window closes so later clicks are instant.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsWindowController()

    static func run() -> Never {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication holds its delegate weakly; without this the optimizer may
        // release it right after assignment and no link would ever be handled.
        withExtendedLifetime(delegate) {
            app.run()
        }
        exit(0)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered before launch finishes so the link that launched us isn't missed.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // false when macOS launched us to open a link or a file.
        let launchedByUser = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if launchedByUser {
            settings.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Local .html files opened with the default browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Router.route(url, source: nil)
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string)
        else { return }
        Router.route(url, source: Self.sender(of: event))
    }

    /// The app that asked macOS to open the link, e.g. Slack.
    private static func sender(of event: NSAppleEventDescriptor) -> LinkSource? {
        guard let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return nil }
        return LinkSource(name: app.localizedName, bundleID: app.bundleIdentifier)
    }
}
