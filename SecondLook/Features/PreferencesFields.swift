import SwiftUI
import SecondLookCore

struct PreferencesFields: View {
    @Binding var settings: RunSettings

    private func minutes(_ path: WritableKeyPath<RunSettings, TimeInterval?>) -> Binding<Double?> {
        Binding(get: { settings[keyPath: path].map { $0 / 60 } },
                set: { settings[keyPath: path] = $0.map { $0 * 60 } })
    }
    var body: some View {
        Section {
            Toggle("Remind reviewer", isOn: $settings.reminders.remindReviewer)
            Toggle("Remind me to add photos", isOn: $settings.reminders.remindPerformer)
            LabeledContent("First delay (minutes)") {
                TextField("Not set", value: minutes(\.reminders.firstDelaySeconds), format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Repeat (minutes)") {
                TextField("Off", value: minutes(\.reminders.repeatSeconds), format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Toggle("Mute reminders", isOn: $settings.reminders.muted)
            Toggle("Snooze", isOn: Binding(
                get: { settings.reminders.snoozedUntil != nil },
                set: { settings.reminders.snoozedUntil = $0 ? Date() : nil }
            ))
            if settings.reminders.snoozedUntil != nil {
                DatePicker("Snooze until", selection: Binding(
                    get: { settings.reminders.snoozedUntil ?? Date() },
                    set: { settings.reminders.snoozedUntil = $0 }
                ))
            }
            Toggle("Quiet hours", isOn: Binding(
                get: { settings.reminders.quietHours != nil },
                set: { settings.reminders.quietHours = $0 ? QuietHours(startMinute: 1320, endMinute: 420) : nil }
            ))
            if settings.reminders.quietHours != nil {
                DatePicker("Quiet hours start", selection: quietTime(start: true), displayedComponents: .hourAndMinute)
                DatePicker("Quiet hours end", selection: quietTime(start: false), displayedComponents: .hourAndMinute)
                Text("22:00–07:00 is an editable sample, not an active schedule.").font(.caption)
            }
        } header: { Text("Reminder preferences") } footer: {
            Text("Saved preferences only. No notifications are sent. Timing has no default cadence; configured delays must be greater than zero.")
        }
        Section {
            LabeledContent("Unreviewed timeout (minutes)") {
                TextField("Off", value: minutes(\.unreviewedTimeoutSeconds), format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("timeoutMinutes")
            }
            if settings.unreviewedTimeoutSeconds != nil {
                Button("Turn timeout off") { settings.unreviewedTimeoutSeconds = nil }
            }
        } header: { Text("Photo retention · separate from reminders") } footer: {
            Text("Off by default. No expiry runs in this local milestone. A later service will apply an enabled timeout to future accepted, unreviewed submissions; changes must not silently delete existing evidence. Open photos have no blanket age limit.")
        }
    }

    private func quietTime(start: Bool) -> Binding<Date> {
        Binding(get: {
            let minute = start ? settings.reminders.quietHours?.startMinute : settings.reminders.quietHours?.endMinute
            let value = minute ?? 0
            let reference = Date(timeIntervalSinceReferenceDate: 14 * 86400 + 43200)
            return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: reference) ?? reference
        }, set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            if start { settings.reminders.quietHours?.startMinute = minute }
            else { settings.reminders.quietHours?.endMinute = minute }
        })
    }
}

struct RunPreferencesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    @State var settings: RunSettings

    var body: some View {
        NavigationStack {
            Form { PreferencesFields(settings: $settings) }
                .navigationTitle("Checklist settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if model.perform({
                                try $0.updateRunSettings(runID: runID, actorID: model.actorID, settings: settings)
                                return true
                            }) == true { dismiss() }
                        }
                    }
                }
        }
    }
}
