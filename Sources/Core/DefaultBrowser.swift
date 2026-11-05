import AppKit

/// Reads and sets the system default browser.
@MainActor
enum DefaultBrowser {
    static var currentBundleID: String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    static var isDvar: Bool {
        currentBundleID == Dvar.bundleID
    }

    /// Where LaunchServices has Dvar.app registered, if anywhere.
    static var installedApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Dvar.bundleID)
    }

    /// Registers Dvar for http, then https. macOS shows its own confirmation
    /// prompt. `completion` runs on a background queue.
    nonisolated static func makeDvarDefault(_ app: URL, completion: @escaping @Sendable (Error?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            if let error {
                completion(error)
                return
            }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https", completion: completion)
        }
    }
}
