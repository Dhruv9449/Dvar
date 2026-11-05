import AppKit

enum CLI {
    static let bundleID = "com.dhruv9449.dvar"

    static let usage = """
    dvar (द्वार, "doorway"): open each link in the right Chrome profile.

    Usage:
      dvar ui                         Open the settings window
      dvar profiles                   List the browser's profiles
      dvar init                       Create a starter config
      dvar rules                      List rules in match order
      dvar add <pattern> <profile>    Add a rule (glob on host or host/path)
          [--regex]                   Treat <pattern> as a regex on the full URL
          [--from <app>]              Only links clicked in this app (name or bundle id);
                                      with --from, <pattern> may be omitted
          [--at <n>]                  Insert at position n (default: end)
      dvar remove <n>                 Remove rule n
      dvar move <n> <m>               Move rule n to position m
      dvar default <profile>|--clear  Profile for links no rule matches
      dvar browser <name>             chrome | chrome-beta | chrome-dev | chrome-canary |
                                      chromium | brave | edge
      dvar test <url> [--from <app>]  Show which profile a URL would open in
      dvar open <url> [--from <app>]  Route and open a URL now
      dvar edit                       Open the config file in $EDITOR
      dvar status                     Paths, browser, and default-browser check
      dvar set-default-browser        Make Dvar the system default browser

    Profiles can be a display name ("Work"), an email, "@domain", or a directory ("Profile 1").
    Config: \(Config.path.path)
    """

    static func run(_ args: [String]) -> Int32 {
        guard let cmd = args.first else {
            print(usage)
            return 0
        }
        let rest = Array(args.dropFirst())
        do {
            switch cmd {
            case "help", "-h", "--help": print(usage)
            case "profiles": try profiles()
            case "init": try initConfig(force: rest.contains("--force"))
            case "rules", "list", "ls": try rules()
            case "add": try add(rest)
            case "remove", "rm": try remove(rest)
            case "move", "mv": try move(rest)
            case "default": try setDefault(rest)
            case "browser": try setBrowser(rest)
            case "test": try test(rest)
            case "open": try open(rest)
            case "edit": try edit()
            case "status": try status()
            case "set-default-browser": try setDefaultBrowser()
            case "ui", "settings": try openUI()
            default: throw RouterError("unknown command \"\(cmd)\" (see dvar help)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - argument helpers

    /// Splits args into positionals and `--flag value` / `--switch` options.
    static func parse(_ args: [String], valued: Set<String>, switches: Set<String> = [])
        throws -> (positional: [String], options: [String: String])
    {
        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if valued.contains(a) {
                guard i + 1 < args.count else { throw RouterError("\(a) needs a value") }
                options[a] = args[i + 1]
                i += 2
            } else if switches.contains(a) {
                options[a] = ""
                i += 1
            } else if a.hasPrefix("--") {
                throw RouterError("unknown option \(a)")
            } else {
                positional.append(a)
                i += 1
            }
        }
        return (positional, options)
    }

    static func index(_ s: String, count: Int, allowEnd: Bool = false) throws -> Int {
        guard let n = Int(s), n >= 1, n <= count + (allowEnd ? 1 : 0) else {
            throw RouterError("\(s) is not a valid rule number (1...\(count + (allowEnd ? 1 : 0)))")
        }
        return n - 1
    }

    static func parseURL(_ s: String) throws -> URL {
        let withScheme = s.contains("://") ? s : "https://" + s
        guard let url = URL(string: withScheme), url.host != nil else { throw RouterError("not a URL: \(s)") }
        return url
    }

    static func describe(_ profile: String, in browser: Browser) -> String {
        let (dir, p) = browser.resolveDirectory(profile)
        guard let p else {
            return dir == nil
                ? "\(profile) (NOT FOUND, links would open without a profile)"
                : "\(profile) (not in known profiles, passed as directory)"
        }
        return "\(p.name) [\(p.directory)\(p.email.map { ", \($0)" } ?? "")]"
    }

    static func warnIfUnknown(_ profile: String, _ browser: Browser) {
        guard let list = try? browser.profiles() else { return }
        if !list.contains(where: { $0.matches(profile) }) {
            let names = list.map { "\"\($0.name)\"" }.joined(separator: ", ")
            print("warning: no profile named \"\(profile)\". Known: \(names)")
        }
    }

    // MARK: - commands

    static func profiles() throws {
        let browser = try Browser.from(try Config.load())
        let list = try browser.profiles()
        let w = max(9, list.map(\.directory.count).max() ?? 0)
        print("DIRECTORY".padding(toLength: w + 2, withPad: " ", startingAt: 0) + "NAME / EMAIL")
        for p in list {
            let email = p.email.map { "  <\($0)>" } ?? ""
            print(p.directory.padding(toLength: w + 2, withPad: " ", startingAt: 0) + p.name + email)
        }
    }

    static func initConfig(force: Bool) throws {
        if Config.exists && !force {
            throw RouterError("\(Config.path.path) already exists (use --force to overwrite)")
        }
        let browser = try Browser.from(Config())
        let list = (try? browser.profiles()) ?? []
        let config = Config(defaultProfile: list.first?.name)
        try config.save()
        print("wrote \(Config.path.path)")
        if !list.isEmpty { print(""); try profiles() }
        print("\nNext: dvar ui (or dvar add <pattern> <profile>), then dvar set-default-browser")
    }

    static func rules() throws {
        let config = try Config.load()
        let browser = try Browser.from(config)
        if config.rules.isEmpty { print("no rules yet (dvar add <pattern> <profile>)") }
        for (i, r) in config.rules.enumerated() {
            print("\(String(i + 1).leftPad(3)). \(r.summary)  →  \(describe(r.profile, in: browser))")
        }
        print("  default  →  " + (config.defaultProfile.map { describe($0, in: browser) } ?? "(browser's last-used profile)"))
    }

    static func add(_ args: [String]) throws {
        let (pos, opt) = try parse(args, valued: ["--from", "--at"], switches: ["--regex"])
        var config = try Config.load()
        var rule: Rule
        switch pos.count {
        case 2: rule = Rule(match: pos[0], profile: pos[1])
        case 1 where opt["--from"] != nil: rule = Rule(profile: pos[0])
        default: throw RouterError("usage: dvar add <pattern> <profile> [--regex] [--from <app>] [--at <n>]")
        }
        if opt["--regex"] != nil {
            guard let p = rule.match else { throw RouterError("--regex needs a pattern") }
            _ = try NSRegularExpression(pattern: p)
            rule.regex = p
            rule.match = nil
        }
        rule.from = opt["--from"]
        let at = try opt["--at"].map { try index($0, count: config.rules.count, allowEnd: true) } ?? config.rules.count
        config.rules.insert(rule, at: at)
        try config.save()
        warnIfUnknown(rule.profile, try Browser.from(config))
        print("added rule #\(at + 1): \(rule.summary) → \(rule.profile)")
    }

    static func remove(_ args: [String]) throws {
        var config = try Config.load()
        guard args.count == 1 else { throw RouterError("usage: dvar remove <n>") }
        let i = try index(args[0], count: config.rules.count)
        let r = config.rules.remove(at: i)
        try config.save()
        print("removed rule #\(i + 1): \(r.summary) → \(r.profile)")
    }

    static func move(_ args: [String]) throws {
        var config = try Config.load()
        guard args.count == 2 else { throw RouterError("usage: dvar move <n> <m>") }
        let from = try index(args[0], count: config.rules.count)
        let to = try index(args[1], count: config.rules.count)
        let r = config.rules.remove(at: from)
        config.rules.insert(r, at: to)
        try config.save()
        try rules()
    }

    static func setDefault(_ args: [String]) throws {
        var config = try Config.load()
        guard args.count == 1 else { throw RouterError("usage: dvar default <profile>|--clear") }
        config.defaultProfile = args[0] == "--clear" ? nil : args[0]
        try config.save()
        if let p = config.defaultProfile { warnIfUnknown(p, try Browser.from(config)) }
        print("default → \(config.defaultProfile ?? "(browser's last-used profile)")")
    }

    static func setBrowser(_ args: [String]) throws {
        var config = try Config.load()
        guard args.count == 1 else { throw RouterError("usage: dvar browser <name>") }
        config.browser = args[0]
        let b = try Browser.from(config)
        try config.save()
        print("browser → \(b.bundleID)\(b.appURL == nil ? " (warning: not installed)" : "")")
    }

    static func source(_ opt: [String: String]) -> SourceApp? {
        opt["--from"].map { SourceApp(name: $0, bundleID: $0) }
    }

    static func test(_ args: [String]) throws {
        let (pos, opt) = try parse(args, valued: ["--from"])
        guard pos.count == 1 else { throw RouterError("usage: dvar test <url> [--from <app>]") }
        let url = try parseURL(pos[0])
        let config = try Config.load()
        let browser = try Browser.from(config)
        let d = Matcher.decide(config, url: url, source: source(opt)) { print("warning: \($0)") }
        let target = d.profile.map { describe($0, in: browser) } ?? "(browser's last-used profile)"
        if let i = d.ruleIndex {
            print("\(target)  via rule #\(i + 1): \(config.rules[i].summary)")
        } else {
            print("\(target)  via default (no rule matched)")
        }
    }

    static func open(_ args: [String]) throws {
        let (pos, opt) = try parse(args, valued: ["--from"])
        guard pos.count == 1 else { throw RouterError("usage: dvar open <url> [--from <app>]") }
        let url = try parseURL(pos[0])
        let done = DispatchSemaphore(value: 0)
        Router.route(url, source: source(opt)) { line in
            print(line)
            done.signal()
        }
        done.wait()
    }

    static func edit() throws {
        if !Config.exists { try Config().save() }
        let editor = ProcessInfo.processInfo.environment["VISUAL"]
            ?? ProcessInfo.processInfo.environment["EDITOR"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        if let editor, !editor.isEmpty {
            p.arguments = ["-c", "\(editor) \"$0\"", Config.path.path]
        } else {
            p.arguments = ["-c", "open -t \"$0\"", Config.path.path]
        }
        try p.run()
        p.waitUntilExit()
        _ = try Config.load()  // surface JSON errors right away
    }

    static func status() throws {
        let config = try Config.load()
        let browser = try Browser.from(config)
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        let handlerID = handler.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "unknown"
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        print("config:          \(Config.path.path)\(Config.exists ? "" : " (missing, run dvar init)")")
        print("rules:           \(config.rules.count)")
        print("browser:         \(browser.bundleID)\(browser.appURL == nil ? " (NOT INSTALLED)" : "")")
        print("profiles from:   \(browser.localStatePath.path)")
        print("app:             \(installed?.path ?? "not registered (run make install)")")
        print("default browser: \(handlerID)\(handlerID == bundleID ? " ✓" : " (run dvar set-default-browser)")")
        print("log:             \(Log.path.path)")
    }

    static func openUI() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw RouterError("Dvar.app is not registered; run make install first")
        }
        // `open` sends a reopen event to a running instance, which shows the window.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", bundleID]
        try p.run()
        p.waitUntilExit()
    }

    static func setDefaultBrowser() throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw RouterError("Dvar.app is not registered; run make install first")
        }
        let group = DispatchGroup()
        var failure: Error?
        for scheme in ["http", "https"] {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                if let error { failure = error }
                group.leave()
            }
        }
        group.wait()
        if let failure { throw RouterError("macOS refused: \(failure.localizedDescription)") }
        print("Dvar is now the default browser (macOS may have asked you to confirm).")
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
