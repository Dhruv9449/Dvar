import Foundation

/// The app a link was clicked in.
struct LinkSource: Sendable {
    let name: String?
    let bundleID: String?

    var label: String {
        name ?? bundleID ?? "unknown"
    }

    /// Lets `--from` and the settings tester use one string for either field.
    init(name: String?, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }

    init(_ nameOrBundleID: String) {
        self.init(name: nameOrBundleID, bundleID: nameOrBundleID)
    }

    func matches(_ query: String) -> Bool {
        let query = query.lowercased()
        return name?.lowercased() == query || bundleID?.lowercased() == query
    }
}

struct Decision: Sendable {
    /// Profile string from the config, unresolved. `nil` lets the browser choose.
    let profile: String?
    /// Index of the matching rule, or `nil` when the default applied.
    let ruleIndex: Int?
}

enum Matcher {
    /// First matching rule wins. A rule with a broken regex is skipped and reported
    /// through `warn`, so one typo never stops links from opening.
    static func decide(
        _ config: Config, url: URL, source: LinkSource?, warn: (String) -> Void = { _ in }
    ) -> Decision {
        for (index, rule) in config.rules.enumerated() {
            do {
                if try matches(rule, url: url, source: source) {
                    return Decision(profile: rule.profile, ruleIndex: index)
                }
            } catch {
                warn("rule #\(index + 1) skipped: \(error)")
            }
        }
        return Decision(profile: config.defaultProfile, ruleIndex: nil)
    }

    static func matches(_ rule: Rule, url: URL, source: LinkSource?) throws -> Bool {
        guard rule.hasConditions else { return false }
        if let pattern = rule.match, !matchesPattern(pattern, url: url) {
            return false
        }
        if let pattern = rule.regex, try !matchesRegex(pattern, url: url) {
            return false
        }
        if let app = rule.from, source?.matches(app) != true {
            return false
        }
        return true
    }

    static func matchesPattern(_ raw: String, url: URL) -> Bool {
        var pattern = raw.trimmingCharacters(in: .whitespaces)
        for scheme in ["https://", "http://"] where pattern.lowercased().hasPrefix(scheme) {
            pattern.removeFirst(scheme.count)
        }
        while pattern.hasSuffix("/") {
            pattern.removeLast()
        }
        guard !pattern.isEmpty else { return false }

        // Host and path are matched separately so a "*" in the host can never span a
        // slash: "*.example.com/x" must not match "evil.com/a.example.com/x".
        let slash = pattern.firstIndex(of: "/")
        let hostPattern = String(pattern[..<(slash ?? pattern.endIndex)])
        let host = url.host?.lowercased() ?? ""
        let hostPatterns = hostPattern.hasPrefix("*.")
            ? [hostPattern, String(hostPattern.dropFirst(2))]  // "*.example.com" covers the apex too
            : [hostPattern]
        guard hostPatterns.contains(where: { glob($0, host) }) else { return false }
        guard let slash else { return true }

        // "/org" covers "/org", "/org/..." and "/org?...", but not "/org-fork".
        let pathPattern = String(pattern[slash...])
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?" + query
        }
        return [pathPattern, pathPattern + "/*", pathPattern + "\\?*"].contains { glob($0, path) }
    }

    static func matchesRegex(_ pattern: String, url: URL) throws -> Bool {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw DvarError("invalid regex \(pattern)")
        }
        let string = url.absoluteString
        return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static func glob(_ pattern: String, _ string: String) -> Bool {
        fnmatch(pattern, string, FNM_CASEFOLD) == 0
    }
}
