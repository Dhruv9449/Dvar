import Foundation

/// One routing rule. Every condition that is set must match.
struct Rule: Codable, Equatable, Sendable {
    /// Glob on the URL without its scheme. Without a "/" it is matched against the
    /// host only, and "*.example.com" also covers "example.com". With a "/" the host
    /// and path are matched separately, and "github.com/org" also covers
    /// "github.com/org/..." (but not "github.com/org-fork").
    var match: String?
    /// Case-insensitive regular expression searched in the full URL.
    var regex: String?
    /// App the link was clicked in, by name ("Slack") or bundle id.
    var from: String?
    /// Display name, email, "@domain", or profile directory ("Profile 1").
    var profile: String

    var hasConditions: Bool {
        match != nil || regex != nil || from != nil
    }

    var summary: String {
        var parts: [String] = []
        if let match { parts.append("match \(match)") }
        if let regex { parts.append("regex /\(regex)/") }
        if let from { parts.append("from \(from)") }
        return parts.isEmpty ? "(no conditions, never matches)" : parts.joined(separator: " and ")
    }
}

/// The contents of `~/.config/dvar/config.json`.
struct Config: Codable, Equatable, Sendable {
    /// Browser id, name or bundle id. `nil` means Google Chrome.
    var browser: String?
    /// Profile for links no rule matches. `nil` lets the browser use its last-used profile.
    var defaultProfile: String?
    /// Tried top to bottom; the first match wins.
    var rules: [Rule]

    private enum CodingKeys: String, CodingKey {
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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        browser = try container.decodeIfPresent(String.self, forKey: .browser)
        defaultProfile = try container.decodeIfPresent(String.self, forKey: .defaultProfile)
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: Paths.config.path)
    }

    /// A missing file is an empty config, so a fresh install still opens links.
    static func load() throws -> Config {
        guard exists else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: Paths.config))
        } catch {
            throw DvarError("invalid config at \(Paths.config.path): \(error)")
        }
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self) + Data("\n".utf8)
        try FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
        try data.write(to: Paths.config, options: .atomic)
    }
}
