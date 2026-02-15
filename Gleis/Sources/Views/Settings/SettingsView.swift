import SwiftUI
import UserNotifications

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var locationService: LocationService
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
                locationSection
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

    private var isLocationEnabled: Bool {
        locationService.authorizationStatus == .authorizedWhenInUse
            || locationService.authorizationStatus == .authorizedAlways
    }

    private enum LocationUsageState {
        case active
        case paused
        case denied
    }

    private var locationUsageState: LocationUsageState {
        guard isLocationEnabled else { return .denied }
        guard settingsManager.appSettings.useLocationForStartStation, locationService.isUpdatingLocation else {
            return .paused
        }
        return .active
    }

    private var locationUsageTitle: String {
        switch locationUsageState {
        case .active: "Active"
        case .paused: "Paused"
        case .denied: "Disabled"
        }
    }

    private var locationUsageColor: Color {
        switch locationUsageState {
        case .active: .green
        case .paused: .orange
        case .denied: .red
        }
    }

    private var locationSection: some View {
        Section {
            // Permission Status (opens Settings)
            Button {
                handleLocationToggle()
            } label: {
                HStack {
                    SettingsRow(icon: "antenna.radiowaves.left.and.right", title: "Location Permission", color: .green)
                    Spacer()
                    Text(isLocationEnabled ? "Allowed" : "Denied").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }.buttonStyle(.plain)

            HStack {
                SettingsRow(icon: "location.fill", title: "Location Services", color: .blue)
                Spacer()
                Circle().fill(locationUsageColor).frame(width: 8, height: 8)
                Text(locationUsageTitle).font(.caption).foregroundStyle(.secondary)
            }

            // Feature Toggles (only show if permission granted)
            if isLocationEnabled {
                Toggle(
                    isOn: Binding(
                        get: { settingsManager.appSettings.useLocationForStartStation },
                        set: { newValue in
                            var settings = settingsManager.appSettings
                            settings.useLocationForStartStation = newValue
                            settingsManager.updateAppSettings(settings)
                            if newValue {
                                locationService.startUpdatingLocation()
                            } else {
                                locationService.stopUpdatingLocation()
                            }
                        }
                    )
                ) { SettingsRow(icon: "mappin.and.ellipse", title: "Auto-Select Nearest Station", color: .blue) }

                if settingsManager.appSettings.useLocationForStartStation {
                    Toggle(
                        isOn: Binding(
                            get: { settingsManager.appSettings.useSmartStationSwap },
                            set: { newValue in
                                var settings = settingsManager.appSettings
                                settings.useSmartStationSwap = newValue
                                settingsManager.updateAppSettings(settings)
                            }
                        )
                    ) {
                        SettingsRow(icon: "arrow.left.arrow.right.circle", title: "Smart Station Swap", color: .purple)
                    }

                    // Show button to clear manual override if user has manually selected a station
                    if settingsManager.trainCommuteConfig.isStartStationManuallySelected {
                        Button {
                            var config = settingsManager.trainCommuteConfig
                            config.isStartStationManuallySelected = false
                            settingsManager.updateConfig(config)
                        } label: {
                            SettingsRow(
                                icon: "arrow.counterclockwise", title: "Resume Auto-Selection", color: .orange
                            )
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                Button {
                    handleLocationToggle()
                } label: {
                    SettingsRow(icon: "location.circle", title: "Turn On Location Services", color: .blue)
                }.buttonStyle(.plain)
            }

            if isLocationEnabled, !settingsManager.appSettings.useLocationForStartStation {
                Button {
                    var settings = settingsManager.appSettings
                    settings.useLocationForStartStation = true
                    settingsManager.updateAppSettings(settings)
                    locationService.startUpdatingLocation()
                } label: {
                    SettingsRow(icon: "location.circle.fill", title: "Turn Location Back On", color: .green)
                }.buttonStyle(.plain)
            }
        } header: {
            Text("Location")
        } footer: {
            if locationUsageState == .active {
                Text("Location services are active. Nearby stations and travel-time suggestions are updating.")
            } else if locationUsageState == .paused {
                Text("Location permission is granted, but active location features are paused.")
            } else if !isLocationEnabled {
                Text("Enable location permission to auto-detect your nearest station. Tap to open Settings.")
            } else if !settingsManager.appSettings.useLocationForStartStation {
                Text("Location permission is granted but auto-selection is disabled.")
            } else if settingsManager.trainCommuteConfig.isStartStationManuallySelected {
                Text("You manually selected a station. Tap 'Resume Auto-Selection' to use nearest station again.")
            } else if !settingsManager.appSettings.useSmartStationSwap {
                Text(
                    "Auto-selection is active. Smart swap ensures the nearest station is always your starting point when swapping routes."
                )
            } else {
                Text("Auto-selection and smart swap are active.")
            }
        }
    }

    private func handleLocationToggle() {
        if locationService.authorizationStatus == .notDetermined {
            locationService.requestAuthorization()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
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
                                    Text("\(item.day.shortName) • \(item.direction == .toWork ? "A→B" : "B→A")").font(
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

#Preview { SettingsView().environmentObject(SettingsManager.shared).environmentObject(LocationService.shared) }
