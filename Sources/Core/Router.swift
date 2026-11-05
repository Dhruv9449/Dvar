import Foundation

enum Router {
    private static let queue = DispatchQueue(label: "com.dhruv9449.dvar.router", qos: .userInitiated)

    /// Picks a profile for `url` and opens it, on a background queue: reading the
    /// profile list can block on a macOS privacy prompt, and a click must never
    /// wait on the main thread. Never fails: any problem falls back to opening the
    /// link without a profile. Every decision is logged; `completion` gets the line.
    static func route(
        _ url: URL, source: LinkSource?, completion: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        queue.async {
            var notes: [String] = []

            let config: Config
            do {
                config = try Config.load()
            } catch {
                notes.append("\(error)")
                config = Config()
            }

            let browser: Browser
            do {
                browser = try Browser.named(config.browser)
            } catch {
                notes.append("\(error); using \(Browser.chrome.name)")
                browser = .chrome
            }

            let decision = Matcher.decide(config, url: url, source: source) { notes.append($0) }
            var directory: String?
            if let profile = decision.profile {
                let resolution = browser.resolveQuickly(profile)
                directory = resolution.directory
                if case .unresolved(let reason) = resolution {
                    notes.append("profile \"\(profile)\" not resolved (\(reason)); opened without a profile")
                }
            }

            let summary = [
                url.absoluteString,
                "from=\(source?.label ?? "-")",
                "->",
                directory ?? "(browser default)",
                "via",
                decision.ruleIndex.map { "rule #\($0 + 1)" } ?? "default",
            ].joined(separator: " ")

            browser.open(url, profileDirectory: directory) { [notes] error in
                var line = summary
                if let error {
                    line += " ERROR \(error.localizedDescription)"
                }
                if !notes.isEmpty {
                    line += " [\(notes.joined(separator: "; "))]"
                }
                Log.append(line)
                completion(line)

                // Refresh the cache for next time, now that the link is open.
                queue.async { _ = try? browser.profiles() }
            }
        }
    }
}
