import Foundation

struct RouterError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One routing rule. All conditions that are set must match (AND).
/// Rules are evaluated top to bottom; the first match wins.
struct Rule: Codable, Equatable {
    /// Glob on the URL without its scheme. No "/" → matched against the host only
    /// ("*.example.com" also matches "example.com"). With "/" → matched against
    /// host + path + query, and "github.com/org" also covers "github.com/org/...".
    var match: String?
    /// Case-insensitive regular expression searched in the full URL.
    var regex: String?
    /// App the link was clicked in: its name ("Slack") or bundle id ("com.tinyspeck.slackmacgap").
    var from: String?
    /// Chrome profile: its display name, its email, or its directory ("Profile 1").
    var profile: String

    var summary: String {
        var parts: [String] = []
        if let match { parts.append("match \(match)") }
        if let regex { parts.append("regex /\(regex)/") }
        if let from { parts.append("from \(from)") }
        return parts.isEmpty ? "(no conditions, never matches)" : parts.joined(separator: " and ")
    }
}

struct Config: Codable, Equatable {
    /// Bundle id or alias of the Chromium browser to launch. Defaults to Google Chrome.
    var browser: String?
    /// Profile for URLs that no rule matches. Unset → Chrome picks its last-used profile.
    var defaultProfile: String?
    var rules: [Rule]

    enum CodingKeys: String, CodingKey {
        case browser
        case defaultProfile = "default"
        case rules
    }

    init(browser: String? = nil, defaultProfile: String? = nil, rules: [Rule] = []) {
        self.browser = browser
        self.defaultProfile = defaultProfile
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browser = try c.decodeIfPresent(String.self, forKey: .browser)
        defaultProfile = try c.decodeIfPresent(String.self, forKey: .defaultProfile)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }

    static var path: URL {
        if let override = ProcessInfo.processInfo.environment["DVAR_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dvar/config.json")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: path.path) }

    /// Missing file → empty config, so a fresh install still opens links.
    static func load() throws -> Config {
        guard exists else { return Config() }
        let data = try Data(contentsOf: path)
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw RouterError("invalid config at \(path.path): \(error)")
        }
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(self)
        try FileManager.default.createDirectory(
            at: Config.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: Config.path, options: .atomic)
    }
}
