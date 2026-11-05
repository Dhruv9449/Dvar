import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeneralSection(model: model)
            RulesSection(model: model)
            TesterSection(model: model)
            Footer(model: model)
        }
        .padding(18)
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Sections

private struct GeneralSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    Picker("Browser", selection: $model.browserID) {
                        ForEach(model.browserChoices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 260)

                    Picker("Unmatched links open in", selection: $model.defaultProfile) {
                        Text("Last-used profile").tag("")
                        ProfileOptions(choices: model.profileChoices(for: model.defaultProfile))
                    }
                    .frame(width: 400)

                    Spacer()
                }

                if model.isDefaultBrowser {
                    Label("Dvar is your default browser", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Label("Dvar isn't your default browser, so links aren't routed yet",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Make default") { model.makeDefaultBrowser() }
                    }
                }

                if model.profileError != nil {
                    ProfileAccessBanner(model: model)
                }
            }
            .padding(6)
        }
    }
}

private struct RulesSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack {
            Text("Rules").font(.headline)
            Text("checked top to bottom, the first match wins. Drag to reorder.")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.addRule()
            } label: {
                Label("Add rule", systemImage: "plus")
            }
        }

        List {
            ForEach(Array($model.rules.enumerated()), id: \.element.id) { index, $rule in
                RuleRow(model: model, rule: $rule, number: index + 1)
            }
            .onMove(perform: model.moveRules)

            if model.rules.isEmpty {
                Text("No rules yet. Every link opens in the profile chosen above.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 220)
    }
}

private struct TesterSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        GroupBox {
            HStack(spacing: 8) {
                Text("Try a link").font(.headline)
                TextField("https://github.com/mycompany/repo", text: $model.testURL)
                    .font(.system(.body, design: .monospaced))
                AppField(text: $model.testSource, placeholder: "Clicked in (optional)")
                    .frame(width: 190)
            }
            .padding(4)

            if let result = model.testResult {
                Text(result)
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], 4)
            }
        }
    }
}

private struct Footer: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack {
            if let message = model.message {
                Text(message.text)
                    .foregroundStyle(message.isError ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Open config file") { NSWorkspace.shared.open(Paths.config) }
                .disabled(!Config.exists)
            Button("Open log") { NSWorkspace.shared.open(Paths.log) }
                .disabled(!FileManager.default.fileExists(atPath: Paths.log.path))
            Button("Revert") { model.reload() }
                .disabled(!model.isDirty)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty)
        }
    }
}

// MARK: - Components

private struct RuleRow: View {
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

                Picker("Kind", selection: $rule.kind) {
                    ForEach(RuleKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)

                TextField(rule.kind.placeholder, text: $rule.pattern)
                    .font(.system(.body, design: .monospaced))
                    .disabled(rule.kind == .any)

                AppField(text: $rule.from, placeholder: "From app (optional)")
                    .frame(width: 170)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                Picker("Profile", selection: $rule.profile) {
                    if rule.profile.isEmpty {
                        Text("Choose…").tag("")
                    }
                    ProfileOptions(choices: model.profileChoices(for: rule.profile))
                }
                .labelsHidden()
                .frame(width: 210)

                Button {
                    model.deleteRule(rule.id)
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

private struct ProfileOptions: View {
    let choices: [ProfileChoice]

    var body: some View {
        ForEach(choices, id: \.self) { Text($0.label).tag($0.value) }
    }
}

/// A text field for an app name, with a menu of the apps currently running.
private struct AppField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: $text)
            Menu {
                Button("Any app") { text = "" }
                Divider()
                ForEach(SettingsModel.runningAppNames, id: \.self) { name in
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

/// Shown when macOS blocks Dvar from reading the browser's profile list.
private struct ProfileAccessBanner: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("macOS is blocking Dvar from reading your browser's profiles, so rules can't pick one.",
                  systemImage: "lock.fill")
                .foregroundStyle(.red)
            Text("Turn on Dvar under Privacy & Security → Full Disk Access (use + and pick it from ~/Applications if it isn't listed), then click Retry. It only has to work once; Dvar remembers the list.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Full Disk Access") {
                    NSWorkspace.shared.open(URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                Button("Show Dvar in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Button("Retry") { model.loadProfiles() }
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
