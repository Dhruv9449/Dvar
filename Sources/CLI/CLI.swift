import AppKit

@MainActor
enum CLI {
    static let help = """
        dvar \(Dvar.version): open each link in the right Chrome profile.

        Usage:
          dvar ui                         Open the settings window
          dvar profiles                   List the browser's profiles
          dvar init [--force]             Create a starter config
          dvar rules                      List rules in match order
          dvar add <pattern> <profile>    Add a rule (glob on host or host/path)
              [--regex]                   Treat <pattern> as a regex on the full URL
              [--from <app>]              Only links clicked in this app (name or bundle id);
                                          with --from, <pattern> may be omitted
              [--at <n>]                  Insert at position n (default: end)
          dvar remove <n>                 Remove rule n
          dvar move <n> <m>               Move rule n to position m
          dvar default <profile>|--clear  Profile for links no rule matches
          dvar browser <name>             \(Browser.supported.map(\.id).joined(separator: " | "))
          dvar test <url> [--from <app>]  Show which profile a URL would open in
          dvar open <url> [--from <app>]  Route and open a URL now
          dvar edit                       Open the config file in $EDITOR
          dvar status                     Paths, browser, and default-browser check
          dvar set-default-browser        Make Dvar the system default browser
          dvar version                    Print the version

        Profiles can be a display name ("Work"), an email, "@domain", or a directory ("Profile 1").
        Config: \(Paths.config.path)
        """

    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            print(help)
            return 0
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "help", "-h", "--help": print(help)
            case "version", "-v", "--version": print(Dvar.version)
            case "ui", "settings": try openSettings()
            case "profiles": try listProfiles()
            case "init": try initConfig(rest)
            case "rules", "list", "ls": try listRules()
            case "add": try addRule(rest)
            case "remove", "rm": try removeRule(rest)
            case "move", "mv": try moveRule(rest)
            case "default": try setDefaultProfile(rest)
            case "browser": try setBrowser(rest)
            case "test": try testURL(rest)
            case "open": try await openURL(rest)
            case "edit": try editConfig()
            case "status": try printStatus()
            case "set-default-browser": try await setDefaultBrowser()
            default: throw DvarError("unknown command \"\(command)\" (see dvar help)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - Rules

    private static func listRules() throws {
        let config = try Config.load()
        let browser = try Browser.named(config.browser)
        if config.rules.isEmpty {
            print("No rules yet. Add one with: dvar add <pattern> <profile>")
        }
        for (index, rule) in config.rules.enumerated() {
            let number = String(index + 1).leftPadded(to: 3)
            print("\(number). \(rule.summary)  →  \(describe(rule.profile, in: browser))")
        }
        let fallback = config.defaultProfile.map { describe($0, in: browser) } ?? "(browser's last-used profile)"
        print("  default  →  \(fallback)")
    }

    private static func addRule(_ arguments: [String]) throws {
        let usage = "usage: dvar add <pattern> <profile> [--regex] [--from <app>] [--at <n>]"
        let args = try Arguments(arguments, options: ["--from", "--at"], flags: ["--regex"])
        var config = try Config.load()

        var rule: Rule
        switch (args.positional.count, args["--from"]) {
        case (2, _): rule = Rule(match: args.positional[0], profile: args.positional[1])
        case (1, .some): rule = Rule(profile: args.positional[0])
        default: throw DvarError(usage)
        }
        rule.from = args["--from"]
        if args.has("--regex") {
            guard let pattern = rule.match else { throw DvarError("--regex needs a pattern") }
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw DvarError("invalid regex \(pattern)")
            }
            rule.regex = pattern
            rule.match = nil
        }

        let position = try args["--at"].map { try ruleIndex($0, count: config.rules.count + 1) }
            ?? config.rules.count
        config.rules.insert(rule, at: position)
        try config.save()
        print("Added rule #\(position + 1): \(rule.summary) → \(rule.profile)")
        warnIfUnknown(rule.profile, browser: try Browser.named(config.browser))
    }

    private static func removeRule(_ arguments: [String]) throws {
        guard arguments.count == 1 else { throw DvarError("usage: dvar remove <n>") }
        var config = try Config.load()
        let index = try ruleIndex(arguments[0], count: config.rules.count)
        let rule = config.rules.remove(at: index)
        try config.save()
        print("Removed rule #\(index + 1): \(rule.summary) → \(rule.profile)")
    }

    private static func moveRule(_ arguments: [String]) throws {
        guard arguments.count == 2 else { throw DvarError("usage: dvar move <n> <m>") }
        var config = try Config.load()
        let from = try ruleIndex(arguments[0], count: config.rules.count)
        let to = try ruleIndex(arguments[1], count: config.rules.count)
        config.rules.insert(config.rules.remove(at: from), at: to)
        try config.save()
        try listRules()
    }

    private static func setDefaultProfile(_ arguments: [String]) throws {
        guard arguments.count == 1 else { throw DvarError("usage: dvar default <profile>|--clear") }
        var config = try Config.load()
        config.defaultProfile = arguments[0] == "--clear" ? nil : arguments[0]
        try config.save()
        print("Default → \(config.defaultProfile ?? "(browser's last-used profile)")")
        if let profile = config.defaultProfile {
            warnIfUnknown(profile, browser: try Browser.named(config.browser))
        }
    }

    private static func setBrowser(_ arguments: [String]) throws {
        guard arguments.count == 1 else { throw DvarError("usage: dvar browser <name>") }
        let browser = try Browser.named(arguments[0])
        var config = try Config.load()
        config.browser = browser == .chrome ? nil : browser.id
        try config.save()
        let installed = browser.applicationURL == nil ? " (warning: not installed)" : ""
        print("Browser → \(browser.name) [\(browser.bundleID)]\(installed)")
    }

    private static func initConfig(_ arguments: [String]) throws {
        let args = try Arguments(arguments, flags: ["--force"])
        if Config.exists && !args.has("--force") {
            throw DvarError("\(Paths.config.path) already exists (use --force to overwrite)")
        }
        let profiles = (try? Browser.chrome.profiles()) ?? []
        try Config(defaultProfile: profiles.first?.name).save()
        print("Wrote \(Paths.config.path)")
        if !profiles.isEmpty {
            print("")
            try listProfiles()
        }
        print("\nNext: dvar ui (or dvar add <pattern> <profile>), then dvar set-default-browser")
    }

    private static func editConfig() throws {
        if !Config.exists {
            try Config().save()
        }
        let environment = ProcessInfo.processInfo.environment
        let editor = [environment["VISUAL"], environment["EDITOR"]].compactMap { $0 }.first { !$0.isEmpty }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path goes in as $0 so it never needs shell quoting.
        process.arguments = ["-c", editor.map { "\($0) \"$0\"" } ?? "open -t \"$0\"", Paths.config.path]
        try process.run()
        process.waitUntilExit()
        _ = try Config.load()  // surface JSON mistakes right away
    }

    // MARK: - Links

    private static func testURL(_ arguments: [String]) throws {
        let args = try Arguments(arguments, options: ["--from"])
        guard args.positional.count == 1 else { throw DvarError("usage: dvar test <url> [--from <app>]") }
        let url = try parseURL(args.positional[0])
        let config = try Config.load()
        let browser = try Browser.named(config.browser)
        let decision = Matcher.decide(config, url: url, source: args["--from"].map(LinkSource.init)) {
            print("warning: \($0)")
        }
        let target = decision.profile.map { describe($0, in: browser) } ?? "(browser's last-used profile)"
        let reason = decision.ruleIndex.map { "rule #\($0 + 1): \(config.rules[$0].summary)" }
            ?? "default (no rule matched)"
        print("\(target)  via \(reason)")
    }

    private static func openURL(_ arguments: [String]) async throws {
        let args = try Arguments(arguments, options: ["--from"])
        guard args.positional.count == 1 else { throw DvarError("usage: dvar open <url> [--from <app>]") }
        let url = try parseURL(args.positional[0])
        let line = await withCheckedContinuation { continuation in
            Router.route(url, source: args["--from"].map(LinkSource.init)) { continuation.resume(returning: $0) }
        }
        print(line)
    }

    // MARK: - System

    private static func listProfiles() throws {
        let browser = try Browser.named(try Config.load().browser)
        let profiles = try browser.profiles()
        let width = max("DIRECTORY".count, profiles.map(\.directory.count).max() ?? 0) + 2
        print("DIRECTORY".rightPadded(to: width) + "NAME / EMAIL")
        for profile in profiles {
            let email = profile.email.map { "  <\($0)>" } ?? ""
            print(profile.directory.rightPadded(to: width) + profile.name + email)
        }
    }

    private static func printStatus() throws {
        let config = try Config.load()
        let browser = try Browser.named(config.browser)
        let current = DefaultBrowser.currentBundleID ?? "unknown"
        let rows: [(String, String)] = [
            ("version", Dvar.version),
            ("config", Paths.config.path + (Config.exists ? "" : " (missing, run dvar init)")),
            ("rules", "\(config.rules.count)"),
            ("browser", "\(browser.name) [\(browser.bundleID)]" + (browser.applicationURL == nil ? " (NOT INSTALLED)" : "")),
            ("profiles from", browser.localState.path),
            ("app", DefaultBrowser.installedApp?.path ?? "not registered (run make install)"),
            ("default browser", current + (DefaultBrowser.isDvar ? " ✓" : " (run dvar set-default-browser)")),
            ("log", Paths.log.path),
        ]
        for (label, value) in rows {
            print("\(label):".rightPadded(to: 17) + value)
        }
    }

    private static func setDefaultBrowser() async throws {
        guard let app = DefaultBrowser.installedApp else {
            throw DvarError("Dvar.app is not registered; run make install first")
        }
        let error = await withCheckedContinuation { continuation in
            DefaultBrowser.makeDvarDefault(app) { continuation.resume(returning: $0) }
        }
        if let error {
            throw DvarError("macOS refused: \(error.localizedDescription)")
        }
        print("Dvar is now the default browser.")
    }

    private static func openSettings() throws {
        guard DefaultBrowser.installedApp != nil else {
            throw DvarError("Dvar.app is not registered; run make install first")
        }
        // `open` sends a reopen event to a running instance, which shows the window.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", Dvar.bundleID]
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - Helpers

    /// Accepts "example.com/x" as well as full URLs.
    static func parseURL(_ string: String) throws -> URL {
        let withScheme = string.contains("://") ? string : "https://" + string
        guard let url = URL(string: withScheme), url.host != nil else {
            throw DvarError("not a URL: \(string)")
        }
        return url
    }

    /// Converts a 1-based rule number to an index in 0..<count.
    private static func ruleIndex(_ string: String, count: Int) throws -> Int {
        guard count > 0 else { throw DvarError("there are no rules yet") }
        guard let number = Int(string), (1...count).contains(number) else {
            throw DvarError("\(string) is not a valid rule number (1...\(count))")
        }
        return number - 1
    }

    private static func describe(_ profile: String, in browser: Browser) -> String {
        switch browser.resolve(profile) {
        case .profile(let match):
            return "\(match.name) [\(match.directory)\(match.email.map { ", \($0)" } ?? "")]"
        case .directory:
            return "\(profile) (not in the profile list, passed as a directory)"
        case .unresolved:
            return "\(profile) (NOT FOUND, links would open without a profile)"
        }
    }

    private static func warnIfUnknown(_ profile: String, browser: Browser) {
        guard let profiles = try? browser.profiles(), !profiles.contains(where: { $0.matches(profile) }) else {
            return
        }
        let names = profiles.map { "\"\($0.name)\"" }.joined(separator: ", ")
        print("warning: no profile named \"\(profile)\". Known: \(names)")
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: " ", count: max(0, width - count)) + self
    }

    func rightPadded(to width: Int) -> String {
        self + String(repeating: " ", count: max(0, width - count))
    }
}
