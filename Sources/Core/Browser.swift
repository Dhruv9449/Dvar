import AppKit

struct BrowserProfile: Codable, Equatable, Sendable {
    let directory: String
    let name: String
    let email: String?

    var label: String {
        email.map { "\(name) (\($0))" } ?? name
    }

    /// Accepts the directory, the display name, the email, or "@domain" for any
    /// email on that domain. Case-insensitive.
    func matches(_ query: String) -> Bool {
        let query = query.lowercased()
        if query.hasPrefix("@"), let email = email?.lowercased() {
            return email.hasSuffix(query)
        }
        return [directory, name, email].contains { $0?.lowercased() == query }
    }

    /// Chromium's own directory names: "Default", "Profile 1", "Profile 2", ...
    static func isDirectoryName(_ string: String) -> Bool {
        string == "Default" || string.wholeMatch(of: /Profile \d+/) != nil
    }
}

enum ProfileResolution: Equatable {
    case profile(BrowserProfile)
    /// Not in the profile list, but shaped like a directory, so it is passed through.
    case directory(String)
    case unresolved(reason: String)

    var directory: String? {
        switch self {
        case .profile(let profile): return profile.directory
        case .directory(let directory): return directory
        case .unresolved: return nil
        }
    }
}

/// A Chromium-based browser that understands `--profile-directory`.
struct Browser: Equatable, Sendable {
    let id: String
    let name: String
    let bundleID: String
    /// Folder under ~/Library/Application Support that holds "Local State".
    let dataDirectory: String

    static let chrome = Browser(
        id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome", dataDirectory: "Google/Chrome")

    static let supported: [Browser] = [
        chrome,
        Browser(id: "chrome-beta", name: "Google Chrome Beta", bundleID: "com.google.Chrome.beta",
                dataDirectory: "Google/Chrome Beta"),
        Browser(id: "chrome-dev", name: "Google Chrome Dev", bundleID: "com.google.Chrome.dev",
                dataDirectory: "Google/Chrome Dev"),
        Browser(id: "chrome-canary", name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary",
                dataDirectory: "Google/Chrome Canary"),
        Browser(id: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium",
                dataDirectory: "Chromium"),
        Browser(id: "brave", name: "Brave", bundleID: "com.brave.Browser",
                dataDirectory: "BraveSoftware/Brave-Browser"),
        Browser(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                dataDirectory: "Microsoft Edge"),
    ]

    /// Looks a browser up by id, name or bundle id. `nil` means Google Chrome.
    static func named(_ query: String?) throws -> Browser {
        guard let query else { return chrome }
        let wanted = query.lowercased()
        if let browser = supported.first(where: {
            [$0.id, $0.name, $0.bundleID].contains { $0.lowercased() == wanted }
        }) {
            return browser
        }
        let ids = supported.map(\.id).joined(separator: ", ")
        throw DvarError("unknown browser \"\(query)\" (supported: \(ids))")
    }

    // MARK: Profiles

    var localState: URL {
        Paths.localStateOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support")
            .appending(path: dataDirectory)
            .appending(path: "Local State")
    }

    /// The last profile list that was read successfully.
    var profileCache: URL {
        Paths.supportDirectory.appending(path: "profiles-\(bundleID).json")
    }

    /// Reads the profile list from the browser's "Local State" file. macOS guards
    /// that folder, so a process without access (a terminal, or Dvar before it is
    /// granted Full Disk Access) falls back to the cache from the last good read.
    func profiles() throws -> [BrowserProfile] {
        do {
            let profiles = try readLocalState()
            if let data = try? JSONEncoder().encode(profiles) {
                try? FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
                try? data.write(to: profileCache, options: .atomic)
            }
            return profiles
        } catch {
            if let cached = cachedProfiles() {
                return cached
            }
            throw DvarError("\(error) Give Dvar Full Disk Access; `dvar ui` shows how.")
        }
    }

    /// The cached list alone, without touching "Local State".
    func cachedProfiles() -> [BrowserProfile]? {
        guard let data = try? Data(contentsOf: profileCache) else { return nil }
        return try? JSONDecoder().decode([BrowserProfile].self, from: data)
    }

    /// For the click path: answers from the cache when it knows the profile, since
    /// reading "Local State" can block while macOS waits on a privacy prompt.
    func resolveQuickly(_ query: String) -> ProfileResolution {
        if let profile = cachedProfiles()?.first(where: { $0.matches(query) }) {
            return .profile(profile)
        }
        return resolve(query)
    }

    func resolve(_ query: String) -> ProfileResolution {
        do {
            if let profile = try profiles().first(where: { $0.matches(query) }) {
                return .profile(profile)
            }
            return BrowserProfile.isDirectoryName(query)
                ? .directory(query)
                : .unresolved(reason: "no \(name) profile matches \"\(query)\"")
        } catch {
            // Never invent a directory: Chrome would silently create an empty profile.
            return BrowserProfile.isDirectoryName(query)
                ? .directory(query)
                : .unresolved(reason: "\(error)")
        }
    }

    private func readLocalState() throws -> [BrowserProfile] {
        let data: Data
        do {
            data = try Data(contentsOf: localState)
        } catch {
            throw DvarError("cannot read \(localState.path): \(error.localizedDescription)")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: [String: Any]]
        else {
            throw DvarError("unexpected format in \(localState.path)")
        }
        return infoCache
            .map { directory, info in
                let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return BrowserProfile(directory: directory, name: info["name"] as? String ?? directory, email: email)
            }
            .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }

    // MARK: Opening links

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Starts a new browser process with `--profile-directory`. When the browser is
    /// already running, that process hands the URL to the running one and exits.
    /// `completion` runs on a background queue.
    func open(_ url: URL, profileDirectory: String?, completion: @escaping @Sendable (Error?) -> Void) {
        guard let applicationURL else {
            completion(DvarError("\(name) is not installed"))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = (profileDirectory.map { ["--profile-directory=\($0)"] } ?? []) + [url.absoluteString]
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            completion(error)
        }
    }
}
