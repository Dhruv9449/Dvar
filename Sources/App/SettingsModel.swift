import AppKit

enum RuleKind: String, CaseIterable, Identifiable {
    case match = "Domain / path"
    case regex = "Regex"
    case any = "Any link"

    var id: Self { self }

    var placeholder: String {
        switch self {
        case .match: return "*.mycompany.com  or  github.com/mycompany"
        case .regex: return #"^https://docs\.google\.com/.*"#
        case .any: return "every link from the app on the right"
        }
    }
}

/// A `Rule` as the settings window edits it: one kind of pattern plus an optional app.
struct EditableRule: Identifiable, Equatable {
    let id = UUID()
    var kind: RuleKind
    var pattern: String
    var from: String
    var profile: String
    /// A hand-written rule can set both `match` and `regex`; the window edits only
    /// the match, and keeps the regex so saving doesn't drop it.
    private var extraRegex: String?

    init(_ rule: Rule) {
        if let match = rule.match {
            (kind, pattern, extraRegex) = (.match, match, rule.regex)
        } else if let regex = rule.regex {
            (kind, pattern) = (.regex, regex)
        } else {
            (kind, pattern) = (.any, "")
        }
        from = rule.from ?? ""
        profile = rule.profile
    }

    init(profile: String) {
        (kind, pattern, from) = (.match, "", "")
        self.profile = profile
    }

    var rule: Rule {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        let from = from.trimmingCharacters(in: .whitespaces)
        return Rule(
            match: kind == .match ? pattern : nil,
            regex: kind == .regex ? pattern : (kind == .match ? extraRegex : nil),
            from: from.isEmpty ? nil : from,
            profile: profile)
    }

    /// Why the rule can't be saved, if it can't.
    var problem: String? {
        let rule = rule
        switch kind {
        case .match where rule.match?.isEmpty != false:
            return "Enter a domain or path"
        case .regex where rule.regex?.isEmpty != false:
            return "Enter a regex"
        case .regex where (try? NSRegularExpression(pattern: rule.regex ?? "")) == nil:
            return "Invalid regex"
        case .any where rule.from == nil:
            return "\"Any link\" needs an app to match on"
        default:
            return profile.isEmpty ? "Choose a profile" : nil
        }
    }
}

struct ProfileChoice: Hashable {
    /// The exact string stored in the config.
    let value: String
    let label: String
}

@MainActor
final class SettingsModel: ObservableObject {
    struct Message {
        let text: String
        let isError: Bool
    }

    @Published var browserID = Browser.chrome.id {
        didSet { if browserID != oldValue { loadProfiles() } }
    }
    /// Empty means the browser's last-used profile.
    @Published var defaultProfile = ""
    @Published var rules: [EditableRule] = []
    @Published var testURL = ""
    @Published var testSource = ""
    @Published private(set) var profiles: [BrowserProfile] = []
    @Published private(set) var profileError: String?
    @Published private(set) var isDefaultBrowser = false
    @Published private(set) var message: Message?

    private var saved = Config()

    init() {
        reload()
    }

    var draft: Config {
        Config(
            browser: browserID == Browser.chrome.id ? nil : browserID,
            defaultProfile: defaultProfile.isEmpty ? nil : defaultProfile,
            rules: rules.map(\.rule))
    }

    var isDirty: Bool {
        Self.canonical(draft) != Self.canonical(saved)
    }

    /// Supported browsers, plus whatever unknown value the config holds so it still shows.
    var browserChoices: [(id: String, name: String)] {
        let known = Browser.supported.map { (id: $0.id, name: $0.name) }
        return known.contains { $0.id == browserID } ? known : known + [(id: browserID, name: browserID)]
    }

    // MARK: Loading and saving

    func reload() {
        do {
            saved = try Config.load()
            message = nil
        } catch {
            saved = Config()
            message = Message(text: "\(error)", isError: true)
        }
        browserID = (try? Browser.named(saved.browser))?.id ?? saved.browser ?? Browser.chrome.id
        defaultProfile = saved.defaultProfile ?? ""
        rules = saved.rules.map(EditableRule.init)
        loadProfiles()
        refreshDefaultBrowser()
    }

    func reloadIfClean() {
        if !isDirty { reload() }
    }

    @discardableResult
    func save() -> Bool {
        if let index = rules.firstIndex(where: { $0.problem != nil }), let problem = rules[index].problem {
            message = Message(text: "Rule \(index + 1): \(problem)", isError: true)
            return false
        }
        do {
            try draft.save()
            saved = draft
            message = Message(text: "Saved. Applies to the next link you click.", isError: false)
            return true
        } catch {
            message = Message(text: "Couldn't save: \(error)", isError: true)
            return false
        }
    }

    /// Reads profiles off the main thread: the read can block while macOS waits on
    /// a privacy prompt, and the window must stay responsive meanwhile.
    func loadProfiles() {
        let id = browserID
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Browser.named(id).profiles() }
            DispatchQueue.main.async {
                guard id == self.browserID else { return }  // the browser changed meanwhile
                switch result {
                case .success(let loaded):
                    self.profiles = loaded
                    self.profileError = nil
                case .failure(let error):
                    self.profiles = []
                    self.profileError = "\(error)"
                }
            }
        }
    }

    // MARK: Rules

    func addRule() {
        rules.append(EditableRule(profile: profiles.first?.name ?? ""))
    }

    func deleteRule(_ id: EditableRule.ID) {
        rules.removeAll { $0.id == id }
    }

    func moveRules(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
    }

    /// Menu choices for a profile picker. The stored string is kept verbatim as the
    /// matching choice's value, so a profile written as an email or "@domain" still
    /// shows as selected, and an unknown one stays visible.
    func profileChoices(for current: String) -> [ProfileChoice] {
        var choices = profiles.map {
            ProfileChoice(value: $0.matches(current) ? current : $0.name, label: $0.label)
        }
        if !current.isEmpty && !profiles.contains(where: { $0.matches(current) }) {
            choices.append(ProfileChoice(value: current, label: "\(current) (not found)"))
        }
        return choices
    }

    /// What the tester shows for the current, possibly unsaved, rules.
    var testResult: String? {
        let raw = testURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        guard let url = try? CLI.parseURL(raw) else { return "Not a valid URL" }
        let app = testSource.trimmingCharacters(in: .whitespaces)
        let decision = Matcher.decide(draft, url: url, source: app.isEmpty ? nil : LinkSource(app))
        let profile = decision.profile.map { name in profiles.first { $0.matches(name) }?.name ?? name }
        let reason = decision.ruleIndex.map { "rule \($0 + 1)" } ?? "no rule matched"
        return "Opens in \(profile ?? "the browser's last-used profile")  (\(reason))"
    }

    // MARK: Default browser

    func refreshDefaultBrowser() {
        isDefaultBrowser = DefaultBrowser.isDvar
    }

    func makeDefaultBrowser() {
        DefaultBrowser.makeDvarDefault(Bundle.main.bundleURL) { error in
            let text = error.map { "macOS refused: \($0.localizedDescription)" }
            DispatchQueue.main.async {
                if let text {
                    self.message = Message(text: text, isError: true)
                }
                self.refreshDefaultBrowser()
            }
        }
    }

    // MARK: Helpers

    /// Treats "chrome", "Google Chrome" and a missing browser as the same value.
    private static func canonical(_ config: Config) -> Config {
        var config = config
        let id = (try? Browser.named(config.browser))?.id ?? config.browser
        config.browser = id == Browser.chrome.id ? nil : id
        return config
    }

    static var runningAppNames: [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        return Set(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
