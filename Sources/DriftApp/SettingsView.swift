import AppKit
import SwiftUI

struct SettingsView: View {

    @ObservedObject var controller: DriftController
    @EnvironmentObject var store: StatusStore

    @State private var selection: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case calendar = "Calendar"
        case presets = "Presets"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                switch selection {
                case .general: GeneralSettings(controller: controller).environmentObject(store)
                case .calendar: CalendarSettings(controller: controller).environmentObject(store)
                case .presets: PresetSettings().environmentObject(store)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {

    @ObservedObject var controller: DriftController
    @EnvironmentObject var store: StatusStore

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchStatus = LaunchAtLogin.statusDescription
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            Section("Startup") {
                Toggle("Launch Drift at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                        launchStatus = LaunchAtLogin.statusDescription
                    }
                LabeledContent("Status", value: launchStatus)
                    .font(.system(size: 11))
                if let launchError {
                    Text(launchError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Section("Status") {
                Picker("Default source", selection: Binding(
                    get: { store.settings.defaultSource },
                    set: { value in store.updateSettings { $0.defaultSource = value } }
                )) {
                    ForEach(DriftStatus.Source.allCases) { Text($0.label).tag($0) }
                }

                LabeledContent("Fallback text") {
                    TextField("", text: Binding(
                        get: { store.settings.fallbackText },
                        set: { value in
                            store.updateSettings {
                                $0.fallbackText = value.isEmpty ? DriftSettings.defaultFallbackText : value
                            }
                        }
                    ))
                    .frame(width: 200)
                }
                Text("Shown whenever a status has expired, is empty, or private mode is on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("Show return time on the Drift screen", isOn: Binding(
                    get: { store.settings.showReturnTime },
                    set: { value in store.updateSettings { $0.showReturnTime = value } }
                ))

                Toggle("Private mode — always show the fallback text", isOn: Binding(
                    get: { store.settings.privateMode },
                    set: { value in store.updateSettings { $0.privateMode = value } }
                ))
                Text("With private mode on, your real status is never displayed and never written to the file the screensaver reads.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Full-screen window") {
                Toggle("Show Drift automatically after inactivity", isOn: Binding(
                    get: { store.settings.idleActivationEnabled },
                    set: { value in store.updateSettings { $0.idleActivationEnabled = value } }
                ))
                if store.settings.idleActivationEnabled {
                    LabeledContent("After") {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { store.settings.idleActivationDelay },
                                    set: { value in store.updateSettings { $0.idleActivationDelay = value.rounded() } }
                                ),
                                in: 30...900, step: 30
                            )
                            Text("\(Int(store.settings.idleActivationDelay / 60)) min")
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }
                Text("Only needed if you are using the full-screen window instead of the installed screensaver. Drift closes on any key or mouse activity, and never delays the Mac locking or sleeping.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                HStack {
                    Button("Preview Drift") { controller.previewDrift() }
                    Button("Show Drift now") { controller.showDrift() }
                }
            }

            Spacer()
        }
        .padding(20)
    }
}

// MARK: - Calendar

private struct CalendarSettings: View {

    @ObservedObject var controller: DriftController
    @EnvironmentObject var store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            Section("Access") {
                HStack(spacing: 6) {
                    Circle().fill(colour).frame(width: 8, height: 8)
                    Text(label).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if store.isSyncing { ProgressView().controlSize(.small) }
                }

                Text("Drift reads your Mac's Calendar directly. Nothing leaves this machine: there is no account, no token and no network request anywhere in Drift.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch store.calendarAccess {
                case .notDetermined:
                    Button("Allow Calendar access…") { controller.requestCalendarAccess() }
                case .denied:
                    Button("Open Privacy & Security…") { controller.openCalendarPrivacySettings() }
                case .authorized, .failing:
                    Button("Check now") { Task { await store.syncCalendar() } }
                        .disabled(store.isSyncing)
                }

                if let error = store.lastCalendarError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Right now") {
                if let cached = store.cachedCalendarStatus {
                    HStack(spacing: 8) {
                        Text(cached.emoji).font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cached.text).font(.system(size: 12, weight: .medium))
                            if let end = cached.expiresAt {
                                Text("Until \(end.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Nothing on your calendar right now.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let lastSync = store.lastSyncDate {
                    LabeledContent("Last checked",
                                   value: DriftFormat.relativeSync(lastSync, now: Date()))
                        .font(.system(size: 11))
                }
            }

            Section("How it works") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(CalendarSettings.behaviourNotes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").font(.system(size: 11))
                            Text(note)
                                .font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }

    static let behaviourNotes: [String] = [
        "Only a meeting actually in progress becomes your status.",
        "The meeting's end time becomes the return time and the expiry, so the status clears itself when the meeting does.",
        "All-day events and meetings you have declined are ignored.",
        "When meetings overlap, the one ending soonest wins.",
        "An emoji is inferred from the event title — lunch, calls, focus blocks and so on — falling back to 🗓️.",
        "Drift re-checks every two minutes, and immediately whenever your calendar changes.",
        "Turn on private mode in General if you would rather not have meeting titles on screen.",
    ]

    private var colour: Color {
        switch store.calendarAccess {
        case .authorized: return .green
        case .failing: return .orange
        case .denied: return .red
        case .notDetermined: return .secondary
        }
    }

    private var label: String {
        switch store.calendarAccess {
        case .authorized: return "Calendar access granted"
        case .failing: return "Access granted, but the last read failed"
        case .denied: return "Calendar access denied"
        case .notDetermined: return "Calendar access not granted yet"
        }
    }
}

// MARK: - Presets

private struct PresetSettings: View {

    @EnvironmentObject var store: StatusStore
    @State private var drafts: [DriftPreset] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Presets appear as one-click buttons in the menu-bar popover.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach($drafts) { $preset in
                HStack(spacing: 8) {
                    TextField("🙂", text: $preset.emoji)
                        .frame(width: 46)
                        .multilineTextAlignment(.center)
                    TextField("Status text", text: $preset.text)
                    Button {
                        drafts.removeAll { $0.id == preset.id }
                        commit()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button {
                    drafts.append(DriftPreset(emoji: "🙂", text: "New preset"))
                    commit()
                } label: {
                    Label("Add preset", systemImage: "plus")
                }
                Button("Save changes", action: commit)
                Spacer()
                Button("Reset to defaults") {
                    drafts = DriftPreset.starters
                    commit()
                }
            }

            Spacer()
        }
        .padding(20)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            drafts = store.presets
        }
    }

    private func commit() {
        store.updatePresets(drafts)
    }
}
