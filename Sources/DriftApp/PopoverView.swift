import SwiftUI

/// Drift's whole interface: pick a status, pick how long, start.
///
/// Two states in one popover — the setup form, and a compact view of the running session.
/// Nothing here starts Drift except the Start Drift button.
struct PopoverView: View {

    @ObservedObject var controller: DriftController
    @ObservedObject var store: StatusStore
    let dismiss: () -> Void

    @State private var status: StatusChoice?
    @State private var duration: DurationChoice?
    @State private var customMessage = ""
    @State private var isWritingCustom = false
    @State private var isPickingCustomTime = false
    @State private var customTime = PopoverView.defaultCustomTime()
    @State private var isStarting = false
    @FocusState private var customFieldFocused: Bool

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let session = store.session {
                activeState(session: session)
            } else {
                setupState
            }
        }
        .frame(width: PopoverView.width)
        .background(escapeKeyCatcher)
        .onAppear(perform: restoreChoices)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Drift")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            GearButton {
                dismiss()
                controller.openSettings()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Setup

    private var setupState: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusSection
            durationSection
            startButton
        }
        .padding(14)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("What are you doing?")

            // Plain stacks rather than a LazyVGrid: a popover sizes itself to its
            // content's ideal height, and a lazy container is exactly the kind of thing
            // that has no ideal height to report.
            VStack(spacing: 6) {
                ForEach(chunked(StatusPreset.all, by: 2), id: \.first?.id) { row in
                    HStack(spacing: 6) {
                        ForEach(row) { preset in
                            ChoiceButton(
                                title: preset.label,
                                isSelected: isSelected(preset),
                                height: 30
                            ) {
                                select(preset)
                            }
                        }
                    }
                }
            }

            Button {
                startWritingCustom()
            } label: {
                Text("Write a custom message…")
                    .font(.system(size: 12))
                    .foregroundStyle(isWritingCustom ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .focusable()
            .padding(.top, 2)

            if isWritingCustom {
                TextField("Back in a bit", text: $customMessage)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .focused($customFieldFocused)
                    .onChange(of: customMessage) { _, new in
                        let trimmed = StatusChoice.sanitise(custom: new)
                        if trimmed != new { customMessage = trimmed }
                        let choice = StatusChoice.custom(trimmed)
                        status = choice
                        store.remember(status: choice)
                    }
            }
        }
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Back in")

            VStack(spacing: 6) {
                ForEach(chunked(PopoverView.durationCells, by: 4), id: \.first) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { cell in
                            switch cell {
                            case .preset(let choice):
                                ChoiceButton(
                                    title: choice.label(),
                                    isSelected: duration == choice,
                                    height: 26
                                ) {
                                    select(choice)
                                }
                            case .custom:
                                ChoiceButton(title: "Custom", isSelected: isPickingCustomTime, height: 26) {
                                    startPickingCustomTime()
                                }
                            }
                        }
                    }
                }
            }

            if isPickingCustomTime {
                DatePicker("", selection: $customTime, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .onChange(of: customTime) { _, _ in startPickingCustomTime() }
            }

            if let duration {
                // Kept live: a popover left open for a while should not promise a return
                // time that has already gone by.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(DriftFormat.backAt(duration.returnTime(from: context.date), now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var startButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: start) {
                Text("Start Drift")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)

            if let startError = controller.startError {
                Text(startError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Active

    private func activeState(session: DriftSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.text)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(DriftFormat.backAt(session.returnTime, now: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                Button {
                    controller.endDrift()
                } label: {
                    Text("End Drift").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button {
                    controller.extendDrift()
                } label: {
                    Text("+10 min").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
        .padding(14)
    }

    // MARK: Pieces

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    /// Escape closes the popover. Handled as a key equivalent so it works wherever the
    /// focus happens to be, including inside the custom-message field.
    private var escapeKeyCatcher: some View {
        Button("") { dismiss() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: Choices

    /// The duration row: the seven chips, then Custom.
    private enum DurationCell: Hashable {
        case preset(DurationChoice)
        case custom
    }

    private static let durationCells: [DurationCell] =
        DurationChoice.presets.map(DurationCell.preset) + [.custom]

    private func chunked<T>(_ items: [T], by size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    private var canStart: Bool {
        status?.text != nil && duration != nil
    }

    private func isSelected(_ preset: StatusPreset) -> Bool {
        if case .preset(let id) = status { return id == preset.id }
        return false
    }

    private func select(_ preset: StatusPreset) {
        let choice = StatusChoice.preset(preset.id)
        status = choice
        isWritingCustom = false
        customFieldFocused = false
        store.remember(status: choice)
    }

    private func startWritingCustom() {
        isWritingCustom = true
        let choice = StatusChoice.custom(customMessage)
        status = choice
        customFieldFocused = true
    }

    private func select(_ choice: DurationChoice) {
        duration = choice
        isPickingCustomTime = false
        store.remember(duration: choice)
    }

    private func startPickingCustomTime() {
        isPickingCustomTime = true
        let choice = DurationChoice.clock(from: customTime)
        duration = choice
        store.remember(duration: choice)
    }

    private func start() {
        guard canStart, let status, let duration, !isStarting else { return }
        isStarting = true
        controller.startDrift(status: status, duration: duration)
        dismiss()
    }

    /// Brings back whatever was picked last time, without acting on it.
    private func restoreChoices() {
        if let last = store.lastStatus, last.text != nil {
            status = last
            if case .custom(let message) = last {
                customMessage = message
                isWritingCustom = true
            }
        }
        if let last = store.lastDuration {
            duration = last
            if case .clock(let hour, let minute) = last {
                isPickingCustomTime = true
                customTime = Calendar.current.date(
                    bySettingHour: hour, minute: minute, second: 0, of: Date()
                ) ?? PopoverView.defaultCustomTime()
            }
        }
    }

    /// Half an hour from now, rounded to the next five minutes — a plausible starting
    /// point for the time picker rather than this exact second.
    private static func defaultCustomTime(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let target = now.addingTimeInterval(30 * 60)
        let minute = calendar.component(.minute, from: target)
        let rounded = ((minute + 4) / 5) * 5
        return calendar.date(bySettingHour: calendar.component(.hour, from: target),
                             minute: min(rounded, 55), second: 0, of: target) ?? target
    }
}

// MARK: - Buttons

/// A preset or duration button: text only, a subtle fill when selected, and a focus ring
/// you can actually see when tabbing.
private struct ChoiceButton: View {

    let title: String
    let isSelected: Bool
    let height: CGFloat
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(
            ChoiceButtonStyle(
                isSelected: isSelected,
                isHovering: isHovering,
                isFocused: isFocused,
                height: height
            )
        )
        .focusable()
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ChoiceButtonStyle: ButtonStyle {

    let isSelected: Bool
    let isHovering: Bool
    let isFocused: Bool
    let height: CGFloat

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(fill(pressed: configuration.isPressed), in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .overlay(
                shape.strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-2)
                    .opacity(isFocused ? 1 : 0)
            )
            .contentShape(shape)
    }

    private func fill(pressed: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(pressed ? 0.30 : 0.20)
        }
        if pressed { return Color.primary.opacity(0.16) }
        return Color.primary.opacity(isHovering ? 0.10 : 0.055)
    }

    private var border: Color {
        isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08)
    }
}

/// The settings gear in the header.
private struct GearButton: View {

    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.primary.opacity(isHovering ? 0.10 : 0))
                )
                .overlay(
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .opacity(isFocused ? 1 : 0)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}
