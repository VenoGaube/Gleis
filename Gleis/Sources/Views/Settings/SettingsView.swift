import SwiftUI
import UserNotifications

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @Environment(\.colorScheme) var colorScheme
    @State private var repeatScheduleToRemove: (day: Weekday, direction: CommuteDirection)?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Settings").font(.largeTitle.bold())
                Spacer()
            }.padding(.horizontal).padding(.top, 13).padding(.bottom, 12)

            List {
                notificationSection
                remindersSection
                aboutSection
            }
        }.background {
            (colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)).ignoresSafeArea(
                edges: .all)
        }.navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .navigationBar).onAppear {
            checkNotificationStatus()
        }
    }

    private func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { notificationStatus = settings.authorizationStatus }
        }
    }

    private var isNotificationEnabled: Bool { notificationStatus == .authorized || notificationStatus == .provisional }

    private var notificationSection: some View {
        Section {
            // Permission Status (opens Settings)
            Button {
                handleNotificationToggle()
            } label: {
                HStack {
                    SettingsRow(icon: "bell.fill", title: "Notification Permission", color: .orange)
                    Spacer()
                    Text(isNotificationEnabled ? "Allowed" : "Denied").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }.buttonStyle(.plain)
        } header: {
            Text("Notifications")
        } footer: {
            if !isNotificationEnabled {
                Text("Enable notification permission to receive train departure reminders. Tap to open Settings.")
            } else {
                Text(
                    "When enabled, you'll receive both a 5-minute warning and an exact departure time alert for your scheduled journeys."
                )
            }
        }
    }

    private func handleNotificationToggle() {
        if notificationStatus == .notDetermined {
            Task {
                do {
                    _ = try await NotificationService.shared.requestAuthorization()
                    checkNotificationStatus()
                } catch { print("Failed to request notification authorization: \(error)") }
            }
        } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                SettingsRow(icon: "info.circle", title: "Version", color: .gray)
                Spacer()
                Text("1.0.0").foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://shop.oebbtickets.at/")!) {
                HStack {
                    SettingsRow(icon: "globe", title: "Data Provider", color: .cyan)
                    Spacer()
                    Text("OEBB").foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                }
            }.tint(.primary)
        } header: {
            Text("About")
        }
    }

    private var remindersSection: some View {
        Section {
            let upcoming = settingsManager.scheduledReminders.filter { $0.leaveTime > Date() }.sorted {
                $0.leaveTime < $1.leaveTime
            }
            let repeatSchedules = activeRepeatSchedules
            if upcoming.isEmpty, repeatSchedules.isEmpty {
                Text("No reminders set.").font(.caption).foregroundStyle(.secondary)
            } else {
                if !repeatSchedules.isEmpty {
                    Text("Repeat").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(repeatSchedules.enumerated()), id: \.offset) { _, item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.schedule.lineNumber).font(.subheadline.weight(.semibold))
                                    Text(item.schedule.departureTimeString).font(.caption).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Image(systemName: "repeat").font(.caption2)
                                    Text(
                                        "\(item.day.shortName) • \(item.direction == .toWork ? "From→To" : "To→From")"
                                    ).font(
                                        .caption)
                                }.foregroundStyle(.orange)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                repeatScheduleToRemove = (item.day, item.direction)
                            } label: {
                                Image(systemName: "bell.slash.fill").foregroundStyle(.red)
                            }.buttonStyle(.plain)
                        }.padding(.vertical, 4)
                    }
                }
                if !upcoming.isEmpty {
                    Text("One-time").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(upcoming) { reminder in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reminder.lineNumber).font(.subheadline.weight(.semibold))
                                Text(reminder.destination).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                cancelReminder(reminder)
                            } label: {
                                Image(systemName: "bell.slash.fill").foregroundStyle(.red)
                            }.buttonStyle(.plain)
                        }.padding(.vertical, 4)
                    }
                }
            }
        } header: {
            Text("Reminders")
        }.onAppear { settingsManager.pruneExpiredReminders() }.confirmationDialog(
            "Remove Repeat Journey?",
            isPresented: Binding(
                get: { repeatScheduleToRemove != nil }, set: { if !$0 { repeatScheduleToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Schedule", role: .destructive) {
                if let item = repeatScheduleToRemove { removeRepeatSchedule(day: item.day, direction: item.direction) }
            }
        } message: {
            Text("This will permanently remove this scheduled train from your repeat journeys.")
        }
    }

    private var activeRepeatSchedules: [(day: Weekday, direction: CommuteDirection, schedule: DaySchedule)] {
        var results: [(Weekday, CommuteDirection, DaySchedule)] = []
        for day in Weekday.mondayFirst {
            if let s = settingsManager.savedCommuteRoute.toWorkSchedules[day] { results.append((day, .toWork, s)) }
            if let s = settingsManager.savedCommuteRoute.toHomeSchedules[day] { results.append((day, .toHome, s)) }
        }
        return results
    }

    private func removeRepeatSchedule(day: Weekday, direction: CommuteDirection) {
        var route = settingsManager.savedCommuteRoute
        route.removeSchedule(for: day, direction: direction)
        settingsManager.updateSavedCommuteRoute(route)
    }

    private func cancelReminder(_ reminder: ScheduledReminder) {
        NotificationService.shared.cancelNotification(id: "\(reminder.id)_fiveMinuteWarning")
        NotificationService.shared.cancelNotification(id: "\(reminder.id)_exactTime")
        settingsManager.removeReminder(connectionId: reminder.id)
    }
}

// MARK: - SettingsRow

struct SettingsRow: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(.white).frame(width: 28, height: 28).background(
                color, in: RoundedRectangle(cornerRadius: 6)
            )
            Text(title)
        }
    }
}

#Preview { SettingsView().environmentObject(SettingsManager.shared) }
