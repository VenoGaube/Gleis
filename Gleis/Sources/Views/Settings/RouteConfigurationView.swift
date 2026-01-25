import SwiftUI

// MARK: - RouteConfigurationView

struct RouteConfigurationView: View {
    let transportType: TransportType
    @EnvironmentObject private var settingsManager: SettingsManager
    @State private var walkingTime: Int = 5
    @State private var bufferTime: Int = 2
    @State private var useDelayInLeaveTime: Bool = false
    @State private var maxConnections: Int = 25
    @State private var activeDays: Set<Weekday> = []
    @State private var showResetConfirm = false

    private var config: RouteConfiguration { settingsManager.config(for: transportType) }
    private var leaveTimePreview: String {
        let totalMinutes = 8 * 60 + 30 - walkingTime - bufferTime
        return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: $walkingTime, in: 1...30) {
                    HStack {
                        Image(systemName: "figure.walk").foregroundStyle(.blue); Text("Walking: \(walkingTime) min")
                    }
                }
                Stepper(value: $bufferTime, in: 0...15) {
                    HStack {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(.green); Text("Buffer: \(bufferTime) min")
                    }
                }
                Toggle(isOn: $useDelayInLeaveTime) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange); Text("Use delays for leave time")
                    }
                }
                Stepper(value: $maxConnections, in: 3...50) {
                    HStack {
                        Image(systemName: "list.number")
                            .foregroundStyle(.purple); Text("Show: \(maxConnections) connections")
                    }
                }
            } header: { Text("Timing") } footer: { Text("Example: Train at 08:30 → Leave by \(leaveTimePreview)") }
            Section("Active Days") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                    ForEach(Weekday.mondayFirst) { day in
                        DayToggle(day: day, isSelected: activeDays.contains(day)) {
                            if activeDays.contains(day) { activeDays.remove(day) } else { activeDays.insert(day) }
                        }
                    }
                }.padding(.vertical, 8)
            }
            Section { Button("Reset to Defaults", role: .destructive) { showResetConfirm = true }.confirmationDialog(
                "Reset to Defaults?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset All Settings", role: .destructive) {
                    Haptics.notification(.warning); settingsManager.resetConfig(for: transportType); loadConfig()
                }
            } message: {
                Text("This will reset all \(transportType.navigationTitle) settings to their default values.")
            } }
        }
        .navigationTitle(transportType.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadConfig() }
        .onChange(of: walkingTime) { _, _ in saveConfig() }
        .onChange(of: bufferTime) { _, _ in saveConfig() }
        .onChange(of: useDelayInLeaveTime) { _, _ in saveConfig() }
        .onChange(of: maxConnections) { _, _ in saveConfig() }
        .onChange(of: activeDays) { _, _ in saveConfig() }
    }

    private func loadConfig() {
        walkingTime = config.walkingTimeMinutes; bufferTime = config.bufferTimeMinutes
        useDelayInLeaveTime = config.usesDelayInLeaveTime; maxConnections = config.displayMaxConnections
        activeDays = config.activeDays
    }

    private func saveConfig() {
        var c = config
        c.walkingTimeMinutes = walkingTime; c.bufferTimeMinutes = bufferTime
        c.useDelayInLeaveTime = useDelayInLeaveTime; c.maxConnections = maxConnections; c.activeDays = activeDays
        settingsManager.updateConfig(c)
    }
}

// MARK: - DayToggle

struct DayToggle: View {
    let day: Weekday
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button(action: action) {
            Text(day.shortName).font(.caption.weight(.semibold)).frame(width: 36, height: 36)
                .background(
                    isSelected ? Color
                        .accentColor : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2)),
                    in: Circle()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }.buttonStyle(.plain)
    }
}

// MARK: - NotificationSettingsView

struct NotificationSettingsView: View {
    let transportType: TransportType
    @EnvironmentObject private var settingsManager: SettingsManager
    @State private var isEnabled = true
    @State private var soundEnabled = true
    @State private var customMessage = ""

    private var config: RouteConfiguration { settingsManager.config(for: transportType) }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Notifications", isOn: $isEnabled)
            } footer: {
                Text("When enabled, you'll receive both a 5-minute warning and an exact departure time alert.")
            }
            Section("Sound") {
                Toggle(isOn: $soundEnabled) {
                    HStack {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(isEnabled ? .blue : .gray); Text("Play Sound")
                    }
                }
            }.disabled(!isEnabled).opacity(isEnabled ? 1 : 0.5)
            Section("Custom Message") {
                TextField("Notification message", text: $customMessage, axis: .vertical).lineLimit(2...4)
            }
            .disabled(!isEnabled).opacity(isEnabled ? 1 : 0.5)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: isEnabled) { _, _ in saveSettings() }
        .onChange(of: soundEnabled) { _, _ in saveSettings() }
        .onChange(of: customMessage) { _, _ in saveSettings() }
    }

    private func loadSettings() {
        let s = config.notificationSettings
        isEnabled = s.isEnabled
        soundEnabled = s.soundEnabled
        customMessage = s.customMessage
    }

    private func saveSettings() {
        var c = config
        c.notificationSettings.isEnabled = isEnabled
        c.notificationSettings.soundEnabled = soundEnabled
        c.notificationSettings.customMessage = customMessage
        settingsManager.updateConfig(c)
    }
}
