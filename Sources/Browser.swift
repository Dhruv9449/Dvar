import AppKit

struct Profile {
    let directory: String
    let name: String
    let email: String?

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return directory.lowercased() == q || name.lowercased() == q || email?.lowercased() == q
    }
}

struct Browser {
    let bundleID: String
    /// Folder under ~/Library/Application Support that holds "Local State".
    let dataDir: String

    static let known: [(aliases: [String], bundleID: String, dataDir: String)] = [
        (["chrome", "google chrome"], "com.google.Chrome", "Google/Chrome"),
        (["chrome-beta", "google chrome beta"], "com.google.Chrome.beta", "Google/Chrome Beta"),
        (["chrome-dev", "google chrome dev"], "com.google.Chrome.dev", "Google/Chrome Dev"),
        (["chrome-canary", "google chrome canary"], "com.google.Chrome.canary", "Google/Chrome Canary"),
        (["chromium"], "org.chromium.Chromium", "Chromium"),
        (["brave", "brave browser"], "com.brave.Browser", "BraveSoftware/Brave-Browser"),
        (["edge", "microsoft edge"], "com.microsoft.edgemac", "Microsoft Edge"),
    ]

    static func from(_ config: Config) throws -> Browser {
        let wanted = (config.browser ?? "chrome").lowercased()
        for b in known where b.aliases.contains(wanted) || b.bundleID.lowercased() == wanted {
            return Browser(bundleID: b.bundleID, dataDir: b.dataDir)
        }
        let names = known.map { $0.aliases[0] }.joined(separator: ", ")
        throw RouterError("unknown browser \"\(config.browser ?? "")\" (supported: \(names), or their bundle ids)")
    }

    var localStatePath: URL {
        if let override = ProcessInfo.processInfo.environment["CHROME_ROUTER_LOCAL_STATE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(dataDir)
            .appendingPathComponent("Local State")
    }

    func profiles() throws -> [Profile] {
        let data: Data
        do {
            data = try Data(contentsOf: localStatePath)
        } catch {
            throw RouterError("cannot read \(localStatePath.path): \(error.localizedDescription)")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let cache = profile["info_cache"] as? [String: [String: Any]]
        else { throw RouterError("unexpected format in \(localStatePath.path)") }

        return cache.map { dir, info in
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Profile(directory: dir, name: info["name"] as? String ?? dir, email: email)
        }.sorted { a, b in
            // "Default" first, then "Profile 1", "Profile 2", ... in numeric order.
            a.directory.localizedStandardCompare(b.directory) == .orderedAscending
        }
    }

    /// Maps a profile string from the config to Chrome's profile directory.
    /// Unknown names are passed through as a directory so Chrome can still try.
    func resolveDirectory(_ query: String) -> (directory: String, profile: Profile?) {
        if let list = try? profiles(), let p = list.first(where: { $0.matches(query) }) {
            return (p.directory, p)
        }
        return (query, nil)
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Launches a new browser process with --profile-directory. If the browser is
    /// already running, that process hands the URL to the running one and exits.
    func open(_ url: URL, profileDirectory: String?, completion: @escaping (Error?) -> Void) {
        guard let appURL else {
            completion(RouterError("\(bundleID) is not installed"))
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = true
        var args: [String] = []
        if let profileDirectory { args.append("--profile-directory=\(profileDirectory)") }
        args.append(url.absoluteString)
        cfg.arguments = args
        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, error in
            completion(error)
        }
    }
}
