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

    var body: some View {
        Form {
            Section("Barra de menús") {
                Picker("Estilo", selection: $settings.menuStyle) {
                    ForEach(MenuStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Vista previa") {
                    MenuBarPreview(store: store, settings: settings)
                }
                Toggle("Colorear las cifras al acercarte al límite", isOn: $settings.colorizeMenuBar)
                Picker("Actualizar cada", selection: $settings.refreshMinutes) {
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
                    Text("Renovar la sesión de Claude Code cuando caduque")
                    Text("Dura 8 horas y solo la renueva el «claude» de la terminal. La renueva como él y la guarda en el mismo sitio del llavero.")
                }
            } header: {
                Text("Servicios")
            } footer: {
                Text("Se detectan solos con la sesión de cada app. Las sesiones se leen en este Mac y solo se envían a su propio servicio (Anthropic, OpenAI, Cursor); Antigravity se consulta en local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Avisos") {
                Toggle("Avisarme al acercarme al límite", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, enabled in
                        if enabled { notifier.requestAuthorization() }
                    }
                Stepper(value: $settings.warnThreshold, in: 50...95, step: 5) {
                    LabeledContent("Primer aviso", value: Fmt.percent(Double(settings.warnThreshold)))
                }
                .disabled(!settings.notificationsEnabled)
                .onChange(of: settings.warnThreshold) { _, value in
                    if settings.criticalThreshold <= value { settings.criticalThreshold = min(100, value + 5) }
                }
                Stepper(value: $settings.criticalThreshold, in: 55...100, step: 5) {
                    LabeledContent("Segundo aviso", value: Fmt.percent(Double(settings.criticalThreshold)))
                }
                .disabled(!settings.notificationsEnabled)
                .onChange(of: settings.criticalThreshold) { _, value in
                    if settings.warnThreshold >= value { settings.warnThreshold = max(50, value - 5) }
                }
                Toggle("Avisarme cuando vuelva el cupo", isOn: $settings.notifyRenewals)
                    .disabled(!settings.notificationsEnabled)
                HStack {
                    Spacer()
                    Button("Probar un aviso") { notifier.sendTest() }
                        .disabled(!settings.notificationsEnabled)
                }
            }

            Section("Panel") {
                Toggle("Mostrar el ritmo semanal", isOn: $settings.showPace)
                Toggle("Mostrar el correo de cada cuenta", isOn: $settings.showAccounts)
                Toggle("Guardar el historial (solo en este Mac)", isOn: $settings.historyEnabled)
                HStack {
                    Spacer()
                    Button("Borrar el historial", role: .destructive) { store.clearHistory() }
                }
            }

            Section("General") {
                Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
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
                        Text("Falta aprobarlo en Ajustes del Sistema › General › Ítems de inicio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Abrir") { SMAppService.openSystemSettingsLoginItems() }
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
                        Text("Token Anxiety \(AppInfo.version)").font(.headline)
                        Text("Hecho con ansiedad, para quemar tokens con cabeza.")
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
        .environment(\.locale, Fmt.locale)
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
            Toggle("En la barra", isOn: Binding(
                get: { settings.showsInMenuBar(id) },
                set: { settings.setShowsInMenuBar(id, $0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!settings.isEnabled(id))
            Toggle("Activado", isOn: Binding(
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
        guard let entry else { return "Buscando…" }
        if let snapshot = entry.snapshot {
            var parts = [snapshot.plan ?? "Detectado"]
            if settings.showAccounts, let account = snapshot.account { parts.append(account) }
            if let error = entry.error, let message = error.errorDescription { parts.append(message) }
            return parts.joined(separator: " · ")
        }
        if let error = entry.error { return error.errorDescription ?? "Error" }
        return entry.installed ? "Detectado" : "No está en este Mac"
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
