import SwiftUI

/// Preset expiry durations. "Never" is the default because most away statuses are
/// cleared by coming back, not by a clock.
enum ExpiryChoice: String, CaseIterable, Identifiable {
    case never = "Never"
    case thirtyMinutes = "30 minutes"
    case oneHour = "1 hour"
    case twoHours = "2 hours"
    case fourHours = "4 hours"
    case endOfDay = "End of day"

    var id: String { rawValue }

    func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .never: return nil
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .twoHours: return now.addingTimeInterval(2 * 60 * 60)
        case .fourHours: return now.addingTimeInterval(4 * 60 * 60)
        case .endOfDay:
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = 18
            components.minute = 0
            let sixPM = calendar.date(from: components) ?? now.addingTimeInterval(4 * 60 * 60)
            return sixPM > now ? sixPM : now.addingTimeInterval(60 * 60)
        }
    }
}

struct MenuBarView: View {

    @ObservedObject var controller: DriftController
    @EnvironmentObject var store: StatusStore

    @State private var draftText = ""
    @State private var draftEmoji = ""
    @State private var useReturnTime = false
    @State private var draftReturnTime = Date()
    @State private var expiryChoice: ExpiryChoice = .never
    @State private var didLoadDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            currentStatusCard
            Divider()

            // Deliberately not wrapped in a ScrollView. A ScrollView has no intrinsic
            // height, and a MenuBarExtra popover sizes itself to fit its content, so a
            // ScrollView here reports an ideal height of zero and the whole middle
            // section collapses — `.frame(maxHeight:)` only sets a ceiling, not a height.
            VStack(alignment: .leading, spacing: 14) {
                sourcePicker

                if store.source == .custom {
                    presetsSection
                    customFieldsSection
                } else {
                    calendarSection
                }
            }
            .padding(14)

            Divider()
            actionsSection
        }
        .frame(width: 340)
        .onAppear(perform: loadDraftIfNeeded)
    }

    // MARK: Current status

    private var currentStatusCard: some View {
        let display = store.currentDisplay
        return HStack(spacing: 12) {
            Text(display.emoji.isEmpty ? "🌙" : display.emoji)
                .font(.system(size: 30))
                .opacity(display.emoji.isEmpty ? 0.35 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(display.text)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                if let subtitle = display.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let expiresAt = display.expiresAt {
                    Text("Expires \(expiresAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)

            if store.settings.privateMode {
                Image(systemName: "eye.slash.fill")
                    .foregroundStyle(.secondary)
                    .help("Private mode is on — Drift shows only the fallback text")
            }
        }
        .padding(14)
    }

    // MARK: Source

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { store.source },
                set: { newSource in
                    store.setSource(newSource)
                    // Prompt for Calendar access at the moment it is first needed, rather
                    // than at launch for someone who only uses custom statuses.
                    if newSource == .calendar { controller.ensureCalendarAccess() }
                }
            )) {
                ForEach(DriftStatus.Source.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRESETS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(store.presets) { preset in
                    Button {
                        store.applyPreset(preset)
                        loadDraft()
                    } label: {
                        HStack(spacing: 6) {
                            Text(preset.emoji)
                            Text(preset.text)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Edit presets in Settings.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Custom fields

    private var customFieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CUSTOM STATUS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("🍜", text: $draftEmoji)
                    .frame(width: 46)
                    .multilineTextAlignment(.center)
                TextField("What are you up to?", text: $draftText)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(commitDraft)

            Toggle(isOn: $useReturnTime) {
                Text("Back at").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            if useReturnTime {
                DatePicker("", selection: $draftReturnTime, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            HStack {
                Text("Expires").font(.system(size: 12))
                Spacer()
                Picker("", selection: $expiryChoice) {
                    ForEach(ExpiryChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            HStack(spacing: 8) {
                Button("Save", action: commitDraft)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Clear") {
                    store.clearCustomStatus()
                    loadDraft()
                }
                Spacer()
            }
        }
    }

    // MARK: Calendar

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CALENDAR")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Circle()
                    .fill(accessColour)
                    .frame(width: 7, height: 7)
                Text(accessLabel)
                    .font(.system(size: 12))
                Spacer()
            }

            if case .authorized = store.calendarAccess {
                if store.cachedCalendarStatus == nil {
                    Text("Nothing on your calendar right now.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let lastSync = store.lastSyncDate {
                    Text("Last checked \(DriftFormat.relativeSync(lastSync, now: Date()))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let error = store.lastCalendarError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch store.calendarAccess {
            case .notDetermined:
                Button("Allow Calendar access…") { controller.requestCalendarAccess() }
                    .font(.system(size: 11))
            case .denied:
                Button("Open Privacy settings…") { controller.openCalendarPrivacySettings() }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
            case .authorized, .failing:
                EmptyView()
            }
        }
    }

    private var accessColour: Color {
        switch store.calendarAccess {
        case .authorized: return .green
        case .failing: return .orange
        case .denied: return .red
        case .notDetermined: return .secondary
        }
    }

    private var accessLabel: String {
        switch store.calendarAccess {
        case .authorized: return "Reading your calendar"
        case .failing: return "Calendar read failed"
        case .denied: return "Calendar access denied"
        case .notDetermined: return "Calendar access not granted yet"
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    controller.showDrift()
                } label: {
                    Label("Show Drift", systemImage: "moon.stars.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    controller.previewDrift()
                } label: {
                    Label("Preview", systemImage: "eye")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // Surfaced here, outside the Calendar section, so a failed check is visible
            // even when the Custom source is selected and that section is not shown.
            if store.source == .custom, let error = store.lastCalendarError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Button {
                    controller.ensureCalendarAccess()
                } label: {
                    if store.isSyncing {
                        Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Check Calendar", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(store.isSyncing)

                Spacer()

                Button("Settings…") { controller.openSettings() }
                Button("Quit") { controller.quit() }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: Draft handling

    private func loadDraftIfNeeded() {
        guard !didLoadDraft else { return }
        didLoadDraft = true
        loadDraft()
    }

    private func loadDraft() {
        let status = store.customStatus
        draftText = status.text
        draftEmoji = status.emoji
        useReturnTime = status.returnTime != nil
        draftReturnTime = status.returnTime ?? Date().addingTimeInterval(3600)
        expiryChoice = .never
    }

    private func commitDraft() {
        let now = Date()
        store.updateCustomStatus(
            text: draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: draftEmoji.trimmingCharacters(in: .whitespaces),
            returnTime: .some(useReturnTime ? draftReturnTime : nil),
            expiresAt: .some(expiryChoice.date(from: now))
        )
        store.setSource(.custom)
    }
}
