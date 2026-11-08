import SwiftUI
import UserNotifications

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var repeatScheduleToRemove: (day: Weekday, direction: CommuteDirection)?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    let scrollToTopTrigger: Int

    private let listTopAnchorId = "settings-list-top-anchor"

    init(scrollToTopTrigger: Int = 0) {
        self.scrollToTopTrigger = scrollToTopTrigger
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Settings").font(.largeTitle.bold())
                Spacer()
            }.padding(.horizontal).padding(.top, 13).padding(.bottom, 12)

            ScrollViewReader { proxy in
                List {
                    notificationSection
                        .id(listTopAnchorId)
                    leaveTimeSection
                    remindersSection
                    #if DEBUG
                    widgetDebugSection
                    #endif
                    aboutSection
                }.onChange(of: scrollToTopTrigger) { _, _ in
                    withAnimation(.easeInOut) { proxy.scrollTo(listTopAnchorId, anchor: .top) }
                }
            }
        }.background {
            Color.screenBackground(colorScheme).ignoresSafeArea(
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

    /// Exposes `useDelayInLeaveTime`, which the leave-time maths has always
    /// supported but which nothing could switch on.
    private var leaveTimeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsManager.trainCommuteConfig.usesDelayInLeaveTime },
                set: { newValue in
                    var config = settingsManager.trainCommuteConfig
                    config.useDelayInLeaveTime = newValue
                    settingsManager.updateConfig(config)
                    Haptics.selection()
                }
            )) {
                SettingsRow(icon: "clock.arrow.trianglehead.counterclockwise.rotate.90", title: "Account For Delays", color: .trainBlue)
            }
        } header: {
            Text("Leave Time")
        } footer: {
            if settingsManager.trainCommuteConfig.usesDelayInLeaveTime {
                Text(
                    "Leave times follow the live delay, so a late train means you can leave later. Turn this off to always plan against the scheduled departure."
                )
            } else {
                Text(
                    "Leave times are based on the scheduled departure. Turn this on to push your leave time back when a train is running late."
                )
            }
        }
    }

    private var notificationSection: some View {
        Section {
            // Permission Status (opens Settings)
            Button {
                handleNotificationToggle()
            } label: {
                settingsValueRow(icon: "bell.fill", title: "Notification Permission", color: .orange) {
                    HStack(spacing: 4) {
                        Text(isNotificationEnabled ? "Allowed" : "Denied").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Toggle(isOn: Binding(
                get: { settingsManager.trainCommuteConfig.notificationSettings.soundEnabled },
                set: { newValue in
                    var config = settingsManager.trainCommuteConfig
                    config.notificationSettings.soundEnabled = newValue
                    settingsManager.updateConfig(config)
                    Haptics.selection()
                }
            )) {
                SettingsRow(icon: "speaker.wave.2.fill", title: "Reminder Sound", color: .purple)
            }
            .disabled(!isNotificationEnabled)

            NavigationLink {
                ReminderMessageEditor()
                    .environmentObject(settingsManager)
            } label: {
                // The message sits under the title so it can wrap in full instead of being cut to one line.
                VStack(alignment: .leading, spacing: 4) {
                    SettingsRow(icon: "text.bubble.fill", title: "Reminder Message", color: .teal)
                    Text(settingsManager.trainCommuteConfig.notificationSettings.customMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            settingsValueRow(icon: "info.circle", title: "Version", color: .gray) {
                Text("1.0.0").foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://shop.oebbtickets.at/")!) {
                settingsValueRow(icon: "globe", title: "Data Provider", color: .cyan) {
                    HStack(spacing: 4) {
                        Text("OEBB").foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                    }
                }
            }.tint(.primary)
        } header: {
            Text("About")
        }
    }

    #if DEBUG
    private var widgetDebugSection: some View {
        Section {
            if let data = AppGroupStorage.loadPrimaryWidgetData() {
                widgetDebugRow(title: "State", value: data.state.rawValue)
                widgetDebugRow(title: "Generated", value: Self.debugDateFormatter.string(from: data.generatedAt))
                widgetDebugRow(title: "Coverage End", value: Self.debugDateFormatter.string(from: data.coverageEnd))
                widgetDebugRow(title: "Route", value: data.routeSignature)
                widgetDebugRow(title: "Signature", value: String(data.snapshotSignature.prefix(44)))
                widgetDebugRow(title: "Connections", value: "\(data.connections.count)")
                if let message = data.stateMessage, !message.isEmpty {
                    widgetDebugRow(title: "Message", value: message)
                }
            } else {
                Text("No widget snapshot stored.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Widget Debug")
        } footer: {
            Text("Debug-only snapshot metadata from App Group storage.")
        }
    }

    @ViewBuilder
    private func widgetDebugRow(title: String, value: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.secondary)
                Text(value)
            }
            .font(.caption)
        } else {
            HStack(alignment: .top) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
            .font(.caption)
        }
    }

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
    #endif

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
                        let stations = stationNames(for: item.direction)
                        reminderRow(
                            spokenSummary: "\(item.day.fullName), \(item.schedule.lineNumber) at \(item.schedule.departureTimeString), \(stations.from) to \(stations.to)",
                            removeAccessibilityLabel: "Remove repeat journey for \(item.day.fullName)",
                            onRemove: { repeatScheduleToRemove = (item.day, item.direction) }
                        ) {
                            HStack(spacing: 6) {
                                Text(item.schedule.lineNumber).font(.subheadline.weight(.semibold))
                                Text(item.schedule.departureTimeString).font(.caption).foregroundStyle(.secondary)
                            }
                            Label {
                                Text("\(item.day.shortName) · \(stations.from) → \(stations.to)")
                            } icon: {
                                Image(systemName: "repeat")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                if !upcoming.isEmpty {
                    Text("One-time").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(upcoming) { reminder in
                        let weekday = Weekday(rawValue: Calendar.current.component(.weekday, from: reminder.departureTime))
                        let departure = reminder.departureTime.formatted(date: .omitted, time: .shortened)
                        reminderRow(
                            spokenSummary: "\(weekday?.fullName ?? ""), \(reminder.lineNumber) at \(departure) to \(reminder.destination)",
                            removeAccessibilityLabel: "Remove reminder for \(reminder.lineNumber) at \(departure)",
                            onRemove: { cancelReminder(reminder) }
                        ) {
                            HStack(spacing: 6) {
                                Text(reminder.lineNumber).font(.subheadline.weight(.semibold))
                                Text(departure).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(weekday?.shortName ?? "") · to \(reminder.destination)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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

    /// Station names for a saved direction, with the generic labels when a station is not picked yet.
    private func stationNames(for direction: CommuteDirection) -> (from: String, to: String) {
        let route = settingsManager.savedCommuteRoute
        let fallbackFrom = direction == .toWork ? "From" : "To"
        let fallbackTo = direction == .toWork ? "To" : "From"
        return (route.fromStation(for: direction)?.name ?? fallbackFrom, route.toStation(for: direction)?.name ?? fallbackTo)
    }

    /// One reminder row, with the remove button moved under the text at accessibility sizes so the text keeps the full width.
    @ViewBuilder
    private func reminderRow<Details: View>(
        spokenSummary: String,
        removeAccessibilityLabel: String,
        onRemove: @escaping () -> Void,
        @ViewBuilder details: () -> Details
    ) -> some View {
        let detailsColumn = VStack(alignment: .leading, spacing: 4, content: details)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenSummary)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                detailsColumn
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "bell.slash.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(removeAccessibilityLabel)
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                detailsColumn
                Spacer(minLength: 8)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(removeAccessibilityLabel)
            }
            .padding(.vertical, 4)
        }
    }

    /// A settings row with a trailing value, stacked under the title at accessibility sizes.
    @ViewBuilder
    private func settingsValueRow<Value: View>(
        icon: String, title: String, color: Color, @ViewBuilder value: () -> Value
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                SettingsRow(icon: icon, title: title, color: color)
                value()
            }
        } else {
            HStack {
                SettingsRow(icon: icon, title: title, color: color)
                Spacer(minLength: 8)
                value()
            }
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
        Task { await CommuteNotificationReconciler.reconcile() }
    }

    private func cancelReminder(_ reminder: ScheduledReminder) {
        NotificationService.shared.cancelNotification(id: "\(reminder.id)_fiveMinuteWarning")
        NotificationService.shared.cancelNotification(id: "\(reminder.id)_exactTime")
        Task { await NotificationService.shared.cancelServiceAlertNotifications(reminderId: reminder.id) }
        settingsManager.removeReminder(connectionId: reminder.id)
    }
}

// MARK: - ReminderMessageEditor

/// Edits the line that leads the five-minute warning. The field existed on
/// `NotificationSettings` from the start but nothing could change it, so every
/// reminder shipped with the built-in default.
struct ReminderMessageEditor: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    private static let maximumLength = 80
    private static let defaultMessage = "🚂 Time to catch your train!"

    var body: some View {
        Form {
            Section {
                TextField("Time to catch your train!", text: $draft, axis: .vertical)
                    .lineLimit(1...)
                    .onChange(of: draft) { _, newValue in
                        if newValue.count > Self.maximumLength {
                            draft = String(newValue.prefix(Self.maximumLength))
                        }
                    }
            } header: {
                Text("Message")
            } footer: {
                Text("Shown at the top of the five-minute warning. \(Self.maximumLength - draft.count) characters left.")
            }

            Section {
                Button("Reset To Default") {
                    draft = Self.defaultMessage
                    Haptics.selection()
                }
                .disabled(draft == Self.defaultMessage)
            }
        }
        .navigationTitle("Reminder Message")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = settingsManager.trainCommuteConfig.notificationSettings.customMessage }
        .onDisappear(perform: persist)
    }

    private func persist() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = settingsManager.trainCommuteConfig
        config.notificationSettings.customMessage = trimmed.isEmpty ? Self.defaultMessage : trimmed
        settingsManager.updateConfig(config)
    }
}

// MARK: - SettingsRow

struct SettingsRow: View {
    let icon: String
    let title: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var iconTileSize: CGFloat = 28

    init(icon: String, title: String, color: Color) {
        self.icon = icon
        self.title = title
        self.color = color
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(.white).frame(width: iconTileSize, height: iconTileSize)
                .background(color, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(title)
        }
    }
}

#Preview { SettingsView().environmentObject(SettingsManager.shared) }
