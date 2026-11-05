import Foundation

struct SourceApp {
    let name: String?
    let bundleID: String?

    var label: String { name ?? bundleID ?? "unknown" }

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return name?.lowercased() == q || bundleID?.lowercased() == q
    }
}

struct Decision {
    /// Profile string from config (unresolved), nil → let the browser choose.
    let profile: String?
    /// 0-based index of the rule that matched, nil → default.
    let ruleIndex: Int?
}

enum Matcher {
    static func glob(_ pattern: String, _ s: String) -> Bool {
        fnmatch(pattern, s, FNM_CASEFOLD) == 0
    }

    static func matchPattern(_ raw: String, url: URL) -> Bool {
        var pattern = raw.trimmingCharacters(in: .whitespaces)
        for scheme in ["https://", "http://"] where pattern.lowercased().hasPrefix(scheme) {
            pattern = String(pattern.dropFirst(scheme.count))
        }
        while pattern.hasSuffix("/") { pattern.removeLast() }
        guard !pattern.isEmpty else { return false }

        let host = (url.host ?? "").lowercased()
        // "*.example.com" should also cover the apex "example.com".
        let variants = pattern.hasPrefix("*.") ? [pattern, String(pattern.dropFirst(2))] : [pattern]

        if !pattern.contains("/") {
            return variants.contains { glob($0, host) }
        }

        var target = host + url.path
        if let q = url.query, !q.isEmpty { target += "?" + q }
        return variants.contains { glob($0, target) || glob($0 + "/*", target) || glob($0 + "\\?*", target) }
    }

    static func matches(_ rule: Rule, url: URL, source: SourceApp?) throws -> Bool {
        if rule.match == nil && rule.regex == nil && rule.from == nil { return false }
        if let m = rule.match, !matchPattern(m, url: url) { return false }
        if let r = rule.regex {
            let re: NSRegularExpression
            do {
                re = try NSRegularExpression(pattern: r, options: [.caseInsensitive])
            } catch {
                throw RouterError("invalid regex \(r): \(error.localizedDescription)")
            }
            let s = url.absoluteString
            if re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil { return false }
        }
        if let f = rule.from {
            guard let source, source.matches(f) else { return false }
        }
        return true
    }

    /// First matching rule wins. A rule with a bad regex is skipped, not fatal,
    /// so one typo never stops links from opening.
    static func decide(_ config: Config, url: URL, source: SourceApp?, warn: (String) -> Void = { _ in }) -> Decision {
        for (i, rule) in config.rules.enumerated() {
            do {
                if try matches(rule, url: url, source: source) {
                    return Decision(profile: rule.profile, ruleIndex: i)
                }
            } catch {
                warn("rule #\(i + 1) skipped: \(error)")
            }
        }
        return Decision(profile: config.defaultProfile, ruleIndex: nil)
    }
}
