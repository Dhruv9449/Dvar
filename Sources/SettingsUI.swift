import AppKit
import SwiftUI

// MARK: - Model

enum RuleKind: String, CaseIterable, Identifiable {
    case match = "Domain / path"
    case regex = "Regex"
    case any = "Any link"
    var id: String { rawValue }

    var placeholder: String {
        switch self {
        case .match: return "*.mycompany.com  or  github.com/mycompany"
        case .regex: return "^https://docs\\.google\\.com/.*"
        case .any: return "every link from the app on the right"
        }
    }
}

struct EditableRule: Identifiable, Equatable {
    let id = UUID()
    var kind: RuleKind
    var pattern: String
    var from: String
    var profile: String
    /// A hand-written rule may carry both match and regex; keep the regex so saving doesn't drop it.
    var preservedRegex: String?

    init(_ r: Rule) {
        if let m = r.match {
            kind = .match; pattern = m; preservedRegex = r.regex
        } else if let re = r.regex {
            kind = .regex; pattern = re
        } else {
            kind = .any; pattern = ""
        }
        from = r.from ?? ""
        profile = r.profile
    }

    init(profile: String) {
        kind = .match; pattern = ""; from = ""; self.profile = profile
    }

    var rule: Rule {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        let f = from.trimmingCharacters(in: .whitespaces)
        return Rule(
            match: kind == .match ? p : nil,
            regex: kind == .regex ? p : (kind == .match ? preservedRegex : nil),
            from: f.isEmpty ? nil : f,
            profile: profile)
    }

    var problem: String? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .match where p.isEmpty: return "Enter a domain or path"
        case .regex where p.isEmpty: return "Enter a regex"
        case .regex where (try? NSRegularExpression(pattern: p)) == nil: return "Invalid regex"
        case .any where from.trimmingCharacters(in: .whitespaces).isEmpty: return "\"Any link\" needs a From app"
        default: break
        }
        return profile.isEmpty ? "Pick a profile" : nil
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var browser = "chrome"
    @Published var defaultProfile = ""  // "" → browser's last-used profile
    @Published var rules: [EditableRule] = []
    @Published var profiles: [Profile] = []
    @Published var profileError: String?
    @Published var isDefaultBrowser = false
    @Published var testURL = ""
    @Published var testFrom = ""
    @Published var message: (text: String, isError: Bool)?
    private var saved = Config()

    init() { reload() }

    var draft: Config {
        Config(browser: browser, defaultProfile: defaultProfile.isEmpty ? nil : defaultProfile,
               rules: rules.map(\.rule))
    }

    var isDirty: Bool { Self.normalized(draft) != Self.normalized(saved) }

    static func normalized(_ c: Config) -> Config {
        var c = c
        if let b = try? Browser.from(c), b.bundleID == "com.google.Chrome" { c.browser = nil }
        return c
    }

    var browserOptions: [String] {
        let known = Browser.known.map { $0.aliases[0] }
        return known.contains(browser) ? known : known + [browser]
    }

    func reload() {
        do {
            saved = try Config.load()
            message = nil
        } catch {
            saved = Config()
            message = ("\(error)", true)
        }
        let wanted = (saved.browser ?? "chrome").lowercased()
        browser = Browser.known.first { $0.aliases.contains(wanted) || $0.bundleID.lowercased() == wanted }?
            .aliases[0] ?? (saved.browser ?? "chrome")
        defaultProfile = saved.defaultProfile ?? ""
        rules = saved.rules.map(EditableRule.init)
        loadProfiles()
        refreshDefaultBrowser()
    }

    func loadProfiles() {
        do {
            profiles = try Browser.from(draft).profiles()
            profileError = nil
        } catch {
            profiles = []
            profileError = "\(error)"
        }
    }

    func refreshDefaultBrowser() {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        isDefaultBrowser = handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == CLI.bundleID
    }

    func makeDefaultBrowser() {
        let app = Bundle.main.bundleURL
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { _ in
                Task { @MainActor in self.refreshDefaultBrowser() }
            }
        }
    }

    @discardableResult
    func save() -> Bool {
        if let i = rules.firstIndex(where: { $0.problem != nil }) {
            message = ("Rule \(i + 1): \(rules[i].problem!)", true)
            return false
        }
        do {
            try draft.save()
            saved = draft
            message = ("Saved. Applies to the next link you click.", false)
            return true
        } catch {
            message = ("Save failed: \(error)", true)
            return false
        }
    }

    func addRule() {
        rules.append(EditableRule(profile: profiles.first?.name ?? ""))
    }

    /// Picker options whose tags include the rule's current string exactly, so a profile
    /// written as an email or "Profile 1" still shows as selected.
    func profileOptions(current: String) -> [(tag: String, label: String)] {
        var opts = profiles.map { p in
            (tag: p.matches(current) ? current : p.name,
             label: p.email.map { "\(p.name) — \($0)" } ?? p.name)
        }
        if !current.isEmpty && !profiles.contains(where: { $0.matches(current) }) {
            opts.append((tag: current, label: "\(current) (not found)"))
        }
        return opts
    }

    func profileLabel(_ s: String) -> String {
        profiles.first { $0.matches(s) }?.name ?? s
    }

    var testResult: String? {
        let raw = testURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        guard let url = try? CLI.parseURL(raw) else { return "Not a valid URL" }
        let from = testFrom.trimmingCharacters(in: .whitespaces)
        let src = from.isEmpty ? nil : SourceApp(name: from, bundleID: from)
        let d = Matcher.decide(draft, url: url, source: src)
        let who = d.profile.map(profileLabel) ?? "the browser's last-used profile"
        let why = d.ruleIndex.map { "rule \($0 + 1)" } ?? "default, no rule matched"
        return "Opens in \(who)  (\(why))"
    }

    static var runningApps: [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Views

struct AppField: View {
    @Binding var text: String
    var placeholder = "From app (optional)"

    var body: some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: $text)
            Menu {
                Button("Any app") { text = "" }
                Divider()
                ForEach(SettingsModel.runningApps, id: \.self) { name in
                    Button(name) { text = name }
                }
            } label: {
                Image(systemName: "app.badge")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick from running apps")
        }
    }
}

struct RuleRow: View {
    @ObservedObject var model: SettingsModel
    @Binding var rule: EditableRule
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                Picker("", selection: $rule.kind) {
                    ForEach(RuleKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField(rule.kind.placeholder, text: $rule.pattern)
                    .font(.system(.body, design: .monospaced))
                    .disabled(rule.kind == .any)
                AppField(text: $rule.from)
                    .frame(width: 170)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("", selection: $rule.profile) {
                    if rule.profile.isEmpty { Text("Choose…").tag("") }
                    ForEach(Array(model.profileOptions(current: rule.profile).enumerated()), id: \.offset) {
                        Text($0.element.label).tag($0.element.tag)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                Button {
                    model.rules.removeAll { $0.id == rule.id }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete rule")
            }
            if let problem = rule.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 24) {
                        Picker("Browser", selection: $model.browser) {
                            ForEach(model.browserOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 220)
                        .onChange(of: model.browser) { _ in model.loadProfiles() }

                        Picker("Unmatched links open in", selection: $model.defaultProfile) {
                            Text("Last-used profile").tag("")
                            ForEach(Array(model.profileOptions(current: model.defaultProfile).enumerated()),
                                    id: \.offset) {
                                Text($0.element.label).tag($0.element.tag)
                            }
                        }
                        .frame(width: 380)
                        Spacer()
                    }
                    HStack {
                        if model.isDefaultBrowser {
                            Label("Chrome Router is your default browser", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Chrome Router is not your default browser, so links won't be routed",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Make default") { model.makeDefaultBrowser() }
                        }
                        Spacer()
                    }
                    if let err = model.profileError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(6)
            }

            HStack {
                Text("Rules").font(.headline)
                Text("checked top to bottom, first match wins. Drag to reorder.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.addRule()
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
            }

            List {
                ForEach(Array($model.rules.enumerated()), id: \.element.id) { i, $rule in
                    RuleRow(model: model, rule: $rule, number: i + 1)
                }
                .onMove { model.rules.move(fromOffsets: $0, toOffset: $1) }
                if model.rules.isEmpty {
                    Text("No rules yet. Every link opens in the default above.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)

            GroupBox {
                HStack(spacing: 8) {
                    Text("Try a link").font(.headline)
                    TextField("https://github.com/mycompany/repo", text: $model.testURL)
                        .font(.system(.body, design: .monospaced))
                    AppField(text: $model.testFrom, placeholder: "clicked in (optional)")
                        .frame(width: 180)
                }
                .padding(4)
                if let result = model.testResult {
                    Text(result)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }
            }

            HStack {
                if let m = model.message {
                    Text(m.text)
                        .foregroundStyle(m.isError ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Open config file") { NSWorkspace.shared.open(Config.path) }
                    .disabled(!Config.exists)
                Button("Open log") { NSWorkspace.shared.open(Log.path) }
                Button("Revert") { model.reload() }
                    .disabled(!model.isDirty)
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty)
            }
        }
        .padding(18)
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: SettingsModel?

    func show() {
        if window == nil {
            let model = SettingsModel()
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Chrome Router"
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("ChromeRouterSettings")
            w.delegate = self
            window = w
            self.model = model
        } else if let model, !model.isDirty {
            model.reload()  // pick up edits made from the CLI meanwhile
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = Self.mainMenu()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pick up edits made from the CLI or by hand, unless there are unsaved changes here.
        if let model, !model.isDirty { model.reload() }
        model?.refreshDefaultBrowser()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to your rules?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.save()
        case .alertSecondButtonReturn: model.reload(); return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a background app with no Dock icon; keeps routing links.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Minimal menu so Cmd+C/V/Z/A work in text fields and Cmd+W/Q do what you expect.
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Chrome Router", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}
