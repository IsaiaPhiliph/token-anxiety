import ServiceManagement
import SwiftUI
import TokenAnxietyCore

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: UsageStore
    let notifier: Notifier

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var notificationAccess: NotificationAccess?
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Style", selection: $settings.menuStyle) {
                    ForEach(MenuStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Preview") {
                    MenuBarPreview(store: store, settings: settings)
                }
                Toggle("Color the figures as you near the limit", isOn: $settings.colorizeMenuBar)
                Picker("Refresh every", selection: $settings.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in Text("\(minutes) min").tag(minutes) }
                }
                .onChange(of: settings.refreshMinutes) { store.reschedule() }
            }

            Section {
                ForEach(ProviderID.allCases) { id in
                    ServiceRow(id: id, settings: settings, entry: store.entries[id]) {
                        Task { await store.refresh(manual: true) }
                    }
                }
                Toggle(isOn: $settings.renewClaudeSession) {
                    Text("Renew Claude Code's session when it expires")
                    Text("It lasts 8 hours and only the “claude” command renews it. The app renews it the same way and saves it in the same Keychain item.")
                }
            } header: {
                Text("Services")
            } footer: {
                Text("Found on their own through each app's session. Sessions are read on this Mac and only sent to their own service (Anthropic, OpenAI, Cursor); Antigravity is asked locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.measureContent) {
                    Text("Measure what fills the context")
                    Text("Reads the size of your prompts, tool results and Claude's replies in Claude Code's logs, on this Mac. Only sizes are kept.")
                }
                if store.advice.hasKey {
                    LabeledContent("Anthropic API key") {
                        HStack {
                            Label("Saved in the Keychain", systemImage: "checkmark.seal")
                                .foregroundStyle(.secondary)
                            Button("Remove") { store.advice.removeKey() }
                        }
                    }
                } else {
                    LabeledContent("Anthropic API key") {
                        HStack {
                            SecureField("sk-ant-…", text: $apiKey)
                                .frame(minWidth: 180)
                            Button("Save") {
                                store.advice.saveKey(apiKey)
                                apiKey = ""
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            } header: {
                Text("Statistics")
            } footer: {
                Text("The key is only for AI advice through the API (Statistics › Advice); through Claude Code or Codex it uses your plans instead. Nothing is sent until you have seen the exact request and pressed Send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Alerts") {
                Toggle("Alert me as I near the limit", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, enabled in
                        if enabled { Task { notificationAccess = await notifier.requestAccess() } }
                    }
                if settings.notificationsEnabled, let access = notificationAccess, let problem = access.problem {
                    HStack {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if access == .notAsked {
                            Button("Allow") { Task { notificationAccess = await notifier.requestAccess() } }
                        } else {
                            Button("Open") { notifier.openSystemSettings() }
                        }
                    }
                }
                Stepper(value: $settings.warnThreshold, in: 50...95, step: 5) {
                    LabeledContent("First alert", value: Fmt.percent(Double(settings.warnThreshold)))
                }
                .disabled(!settings.notificationsEnabled)
                .onChange(of: settings.warnThreshold) { _, value in
                    if settings.criticalThreshold <= value { settings.criticalThreshold = min(100, value + 5) }
                }
                Stepper(value: $settings.criticalThreshold, in: 55...100, step: 5) {
                    LabeledContent("Second alert", value: Fmt.percent(Double(settings.criticalThreshold)))
                }
                .disabled(!settings.notificationsEnabled)
                .onChange(of: settings.criticalThreshold) { _, value in
                    if settings.warnThreshold >= value { settings.warnThreshold = max(50, value - 5) }
                }
                Toggle("Alert me when the quota comes back", isOn: $settings.notifyRenewals)
                    .disabled(!settings.notificationsEnabled)
                HStack {
                    Spacer()
                    Button("Send a test alert") { notifier.sendTest() }
                        .disabled(!settings.notificationsEnabled)
                }
            }

            Section("Panel") {
                Toggle("Show the weekly pace", isOn: $settings.showPace)
                Toggle("Show each account's email", isOn: $settings.showAccounts)
                Toggle("Keep the history (on this Mac only)", isOn: $settings.historyEnabled)
                HStack {
                    Spacer()
                    Button("Clear the history", role: .destructive) { store.clearHistory() }
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        loginStatus = LoginItem.status
                        launchAtLogin = LoginItem.isEnabled || loginStatus == .requiresApproval
                    }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve it in System Settings › General › Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        Text(verbatim: "Token Anxiety \(AppInfo.version)").font(.headline)
                        Text("Made with anxiety, to burn tokens wisely.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 680)
        .onAppear {
            loginStatus = LoginItem.status
            launchAtLogin = LoginItem.isEnabled
        }
        .task { notificationAccess = await notifier.access() }
        // Back from System Settings, where the user may have changed it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notificationAccess = await notifier.access() }
        }
        .environment(\.locale, Fmt.locale)
    }
}

private extension NotificationAccess {
    /// Why the alerts would not show up; nil when they do.
    var problem: String? {
        switch self {
        case .denied: String(localized: "macOS blocks Token Anxiety's alerts: turn on “Allow notifications”.")
        case .quiet: String(localized: "Alerts don't show on screen: tick “Desktop” in its notifications.")
        case .notAsked: String(localized: "The app still needs permission to alert you.")
        case .allowed, .unavailable: nil
        }
    }
}

private struct ServiceRow: View {
    let id: ProviderID
    let settings: AppSettings
    let entry: UsageStore.Entry?
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(id: id, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(id == .codex ? "ChatGPT / Codex" : id.displayName)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("In menu bar", isOn: Binding(
                get: { settings.showsInMenuBar(id) },
                set: { settings.setShowsInMenuBar(id, $0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!settings.isEnabled(id))
            Toggle("On", isOn: Binding(
                get: { settings.isEnabled(id) },
                set: { enabled in
                    settings.setEnabled(id, enabled)
                    if enabled { refresh() }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var status: String {
        guard let entry else { return String(localized: "Looking…") }
        if let snapshot = entry.snapshot {
            var parts = [snapshot.plan ?? String(localized: "Found")]
            if settings.showAccounts, let account = snapshot.account { parts.append(account) }
            if let error = entry.error, let message = error.errorDescription { parts.append(message) }
            return parts.joined(separator: " · ")
        }
        if let error = entry.error { return error.errorDescription ?? String(localized: "Error") }
        return entry.installed ? String(localized: "Found") : String(localized: "Not on this Mac")
    }
}

/// The real status item image for the current figures, on a dark menu bar.
private struct MenuBarPreview: View {
    let store: UsageStore
    let settings: AppSettings

    var body: some View {
        let ids = store.menuBarProviders
        let items = (ids.isEmpty ? [ProviderID.claude, .codex] : ids).map { id in
            let snapshot = store.entries[id]?.snapshot ?? Demo.snapshot(for: id)
            return MenuBarRenderer.Item(provider: id, primary: snapshot.primary?.usedPercent,
                                        secondary: snapshot.secondary?.usedPercent, dimmed: false)
        }
        let options = MenuBarRenderer.Options(style: settings.menuStyle, colorize: settings.colorizeMenuBar,
                                              warn: Double(settings.warnThreshold),
                                              critical: Double(settings.criticalThreshold), dark: true)
        let image = MenuBarRenderer.image(items: items, options: options, height: 22)
        return Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.78)))
    }
}
