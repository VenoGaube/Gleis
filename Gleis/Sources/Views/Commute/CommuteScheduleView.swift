import SwiftUI

// MARK: - CommuteScheduleView

struct CommuteScheduleView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @State private var route: SavedCommuteRoute = .init()
    @State private var showStationAPicker = false
    @State private var showStationBPicker = false
    @State private var selectedDirection: CommuteDirection = .toWork
    @State private var selectedDay: Weekday?
    @State private var showTravelTimeSheet: Station?
    @State private var showBufferTimeSheet: Station?
    @State private var showResetConfirm = false
    @State private var stations: [Station] = []
    @State private var pulseHint = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var showCopySheet: Weekday?
    @Environment(\.colorScheme) var colorScheme

    private var hasSchedules: Bool { !route.toWorkSchedules.isEmpty || !route.toHomeSchedules.isEmpty }
    private var recentStations: [Station] { settingsManager.trainCommuteConfig.recentStations }
    private var favoriteStations: [Station] { settingsManager.trainCommuteConfig.favoriteStations }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Repeat Journeys")
                    .font(.largeTitle.bold())
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 13)
            .padding(.bottom, 12)

            List {
                stationsSection
                directionPicker
                if currentFromStation != nil {
                    travelTimeSection
                }
                scheduleSection
                Section {
                    Button("Reset to Defaults", role: .destructive) { showResetConfirm = true }.confirmationDialog(
                        "Reset to Defaults?",
                        isPresented: $showResetConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Reset All Settings", role: .destructive) {
                            Haptics.notification(.warning); route = SavedCommuteRoute(); save()
                        }
                    } message: {
                        Text("This will clear all stations, schedules, and reset timing to defaults.")
                    }
                }
            }
        }
        .background {
            (colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground))
                .ignoresSafeArea(edges: .all)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            route = settingsManager
                .savedCommuteRoute; stations = await (try? TransportService.shared.fetchStations(for: .trainCommute)) ??
                []
        }
        .onAppear { withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulseHint = true } }
        .onDisappear { pulseHint = false } // Stop animation when view disappears
        .sheet(isPresented: $showStationAPicker) { StationPickerSheet(
            title: "Station A",
            stations: stations,
            recentStations: recentStations,
            favoriteStations: favoriteStations,
            nearbyStations: [],
            searchHandler: searchStations,
            onToggleFavorite: toggleFavorite,
            selection: Binding(get: { route.homeStation }, set: { handleStationAChange($0) })
        ) }
        .sheet(isPresented: $showStationBPicker) { StationPickerSheet(
            title: "Station B",
            stations: stations,
            recentStations: recentStations,
            favoriteStations: favoriteStations,
            nearbyStations: [],
            searchHandler: searchStations,
            onToggleFavorite: toggleFavorite,
            selection: Binding(get: { route.workStation }, set: { handleStationBChange($0) })
        ) }
        .sheet(item: $selectedDay) { day in
            if let from = currentFromStation, let to = currentToStation {
                DayTrainPicker(
                    day: day,
                    from: from,
                    to: to,
                    direction: selectedDirection,
                    route: $route,
                    onSave: save,
                    onFirstSchedule: {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            displayToast("🎉 Great start! Keep going to complete your week", type: .success)
                        }
                    }
                )
            }
        }
        .sheet(item: $showTravelTimeSheet) { station in TravelTimeSheet(
            station: station,
            currentValue: settingsManager.trainCommuteConfig.travelTime(for: station.id)
        ) { time in saveTravelTime(time, for: station) } }
        .sheet(item: $showBufferTimeSheet) { station in BufferTimeSheet(
            station: station,
            currentValue: settingsManager.trainCommuteConfig.bufferTime(for: station.id)
        ) { time in saveBufferTime(time, for: station) } }
        .sheet(item: $showCopySheet) { day in
            CopyScheduleSheet(
                sourceDay: day,
                sourceSchedule: route.schedule(for: day, direction: selectedDirection),
                direction: selectedDirection,
                route: $route,
                onSave: {
                    save()
                    rescheduleAllNotifications()
                },
                onCopied: { message in
                    displayToast(message, type: .success)
                }
            )
        }
        .overlay(alignment: .top) {
            if showToast {
                ToastView(message: toastMessage, type: toastType)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation {
                                showToast = false
                            }
                        }
                    }
            }
        }
    }

    private var currentFromStation: Station? { selectedDirection == .toWork ? route.homeStation : route.workStation }
    private var currentToStation: Station? { selectedDirection == .toWork ? route.workStation : route.homeStation }

    private var stationsSection: some View {
        Section {
            VStack(spacing: 0) {
                LargeStationCard(label: "A", station: route.homeStation, color: .green) {
                    showStationAPicker = true
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                RouteVisualizer(
                    fromStation: route.homeStation,
                    toStation: route.workStation,
                    direction: selectedDirection
                )
                .padding(.vertical, 4)

                LargeStationCard(label: "B", station: route.workStation, color: .red) {
                    showStationBPicker = true
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            if hasSchedules {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        Text("Changing stations will archive your current schedules")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.1))
                    )
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var directionPicker: some View {
        Section {
            Picker("Direction", selection: $selectedDirection) {
                Text("A → B").tag(CommuteDirection.toWork); Text("B → A").tag(CommuteDirection.toHome)
            }
            .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets(
                top: 8,
                leading: 0,
                bottom: 8,
                trailing: 0
            ))
        }
    }

    private var travelTimeSection: some View {
        Section("Timing for \(selectedDirection == .toWork ? "A → B" : "B → A")") {
            let fromStation = currentFromStation
            let travelTime = fromStation.flatMap { settingsManager.trainCommuteConfig.travelTime(for: $0.id) }
            let bufferTime = fromStation.flatMap { settingsManager.trainCommuteConfig.bufferTime(for: $0.id) }
            if let time = travelTime {
                HStack {
                    Label("\(time) min to station", systemImage: "figure.walk")
                    Spacer()
                    if let station = fromStation {
                        Button("Edit") { showTravelTimeSheet = station }.font(.subheadline)
                    }
                }
            } else if let station = fromStation {
                Button { showTravelTimeSheet = station } label: {
                    HStack {
                        Label("Set travel time to \(station.name)", systemImage: "plus.circle.fill")
                            .opacity(pulseHint ? 0.7 : 1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if let buffer = bufferTime {
                HStack {
                    Label("\(buffer) min buffer", systemImage: "clock.badge.checkmark").foregroundStyle(.orange)
                    Spacer()
                    if let station = fromStation {
                        Button("Edit") { showBufferTimeSheet = station }.font(.subheadline)
                    }
                }
            } else if let station = fromStation {
                Button { showBufferTimeSheet = station } label: {
                    HStack {
                        Label("Set buffer time", systemImage: "plus.circle.fill").foregroundStyle(.orange)
                            .opacity(pulseHint ? 0.7 : 1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            if !route.isConfigured {
                ScheduleEmptyState()
            } else {
                let fromStation = currentFromStation
                let travelTime = fromStation.flatMap { settingsManager.trainCommuteConfig.travelTime(for: $0.id) } ?? 0
                let bufferTime = fromStation.flatMap { settingsManager.trainCommuteConfig.bufferTime(for: $0.id) } ?? 0
                let hasAnySchedule = !route.toWorkSchedules.isEmpty || !route.toHomeSchedules.isEmpty

                if !hasAnySchedule {
                    ReadyToScheduleHint()
                }

                ForEach(Weekday.mondayFirst) { day in
                    let hasNotification = route.schedule(for: day, direction: selectedDirection) != nil
                    let hasSchedule = route.schedule(for: day, direction: selectedDirection) != nil
                    DayScheduleRow(
                        day: day,
                        schedule: route.schedule(for: day, direction: selectedDirection),
                        walkingTime: travelTime,
                        bufferTime: bufferTime,
                        hasNotification: hasNotification,
                        onTap: { selectedDay = day },
                        onClear: {
                            cancelNotificationsForSchedule(day: day, direction: selectedDirection)
                            route.removeSchedule(for: day, direction: selectedDirection)
                            save()
                            displayToast("Cleared \(day.fullName) schedule", type: .info)
                        },
                        onCopy: hasSchedule ? { showCopySheet = day } : nil
                    )
                }
            }
        } header: {
            if route.isConfigured {
                Text("Schedule for \(selectedDirection == .toWork ? "A → B" : "B → A")")
            }
        }
    }

    private func clearAllSchedules() {
        route.toWorkSchedules = [:]; route.toHomeSchedules = [:]; NotificationService.shared
            .cancelAllCommuteNotifications()
    }

    private func save() { settingsManager.updateSavedCommuteRoute(route) }

    private func displayToast(_ message: String, type: ToastView.ToastType = .info) {
        toastMessage = message
        toastType = type
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showToast = true
        }
    }

    private func handleStationAChange(_ newStation: Station?) {
        let oldHomeStation = route.homeStation
        let oldWorkStation = route.workStation

        // Handle archiving/restoring via SettingsManager
        settingsManager.handleStationChange(
            oldStart: oldHomeStation,
            oldEnd: oldWorkStation,
            newStart: newStation,
            newEnd: oldWorkStation
        )

        // Update local route from settings manager (which has restored schedules)
        route = settingsManager.savedCommuteRoute

        // Reschedule notifications for restored schedules
        rescheduleAllNotifications()
    }

    private func handleStationBChange(_ newStation: Station?) {
        let oldHomeStation = route.homeStation
        let oldWorkStation = route.workStation

        // Handle archiving/restoring via SettingsManager
        settingsManager.handleStationChange(
            oldStart: oldHomeStation,
            oldEnd: oldWorkStation,
            newStart: oldHomeStation,
            newEnd: newStation
        )

        // Update local route from settings manager (which has restored schedules)
        route = settingsManager.savedCommuteRoute

        // Reschedule notifications for restored schedules
        rescheduleAllNotifications()
    }

    private func rescheduleAllNotifications() {
        Task {
            // Cancel existing commute notifications first
            NotificationService.shared.cancelAllCommuteNotifications()

            // Reschedule for all existing schedules
            let config = settingsManager.trainCommuteConfig
            for (day, schedule) in route.toWorkSchedules {
                try? await NotificationService.shared.scheduleCommuteNotification(
                    route: route, day: day, schedule: schedule, direction: .toWork, config: config
                )
            }
            for (day, schedule) in route.toHomeSchedules {
                try? await NotificationService.shared.scheduleCommuteNotification(
                    route: route, day: day, schedule: schedule, direction: .toHome, config: config
                )
            }
        }
    }

    private func cancelNotificationsForSchedule(day: Weekday, direction: CommuteDirection) {
        NotificationService.shared.cancelCommuteNotification(day: day, direction: direction)
    }

    private func saveTravelTime(_ minutes: Int?, for station: Station) {
        var config = settingsManager.trainCommuteConfig
        config.setTravelTime(minutes, for: station.id)
        settingsManager.updateConfig(config)
    }

    private func saveBufferTime(_ minutes: Int?, for station: Station) {
        var config = settingsManager.trainCommuteConfig
        config.setBufferTime(minutes, for: station.id)
        settingsManager.updateConfig(config)
    }
}

// MARK: - LargeStationCard

struct LargeStationCard: View {
    let label: String
    let station: Station?
    let color: Color
    let onTap: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            Haptics.impact(.light)
            onTap()
        }) {
            VStack(alignment: .leading, spacing: 12) {
                // Header with label
                HStack(spacing: 8) {
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                    Text("Station \(label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                // Station name or empty state
                if let station {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(station.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .scalableText(minimumScale: 0.7)

                        // Lines as badges
                        if !station.lines.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(Array(station.lines.prefix(5)), id: \.self) { line in
                                        Text(line)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.lineColor(for: line), in: Capsule())
                                    }
                                    if station.lines.count > 5 {
                                        Text("+\(station.lines.count - 5)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tap to select \(label == "A" ? "starting point" : "destination")")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 4) {
                            Image(systemName: "hand.tap.fill")
                                .font(.caption)
                            Text(label == "A" ? "Choose your home/work station" : "Choose your destination station")
                                .font(.caption)
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : .white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        station != nil ? color
                            .opacity(0.3) : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2)),
                        lineWidth: station != nil ? 2 : 1
                    )
            )
            .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.06), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel("Station \(label): \(station?.name ?? "Not selected")")
        .accessibilityHint("Tap to select station \(label)")
    }
}

// MARK: - RouteVisualizer

struct RouteVisualizer: View {
    let fromStation: Station?
    let toStation: Station?
    let direction: CommuteDirection
    @State private var pulseAnimation = false
    @Environment(\.colorScheme) var colorScheme

    var showArrow: Bool {
        fromStation != nil || toStation != nil
    }

    var rotationAngle: Double {
        direction == .toHome ? 180 : 0
    }

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(showArrow ? Color.accentColor : Color.secondary.opacity(0.3))
                        .opacity(pulseAnimation ? 0.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true).delay(Double(i) * 0.2),
                            value: pulseAnimation
                        )
                }
            }
            .frame(height: 28)
            .rotationEffect(.degrees(rotationAngle))
            .animation(.spring(response: 0.6, dampingFraction: 0.7), value: rotationAngle)
            .onAppear {
                pulseAnimation = true
            }
            Spacer()
        }
    }
}

// MARK: - CompactStationButton

struct CompactStationButton: View {
    let label: String; let station: Station?; let color: Color; let onTap: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(.white).frame(width: 18, height: 18)
                    .background(
                        color,
                        in: Circle()
                    )
                Text(station?.name ?? "Select")
                    .font(.subheadline)
                    .foregroundStyle(station == nil ? .secondary : .primary)
                    .scalableText(minimumScale: 0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.08) : Color.gray.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Station \(label): \(station?.name ?? "Not selected")")
        .accessibilityHint("Tap to select station \(label)")
    }
}

// MARK: - DayScheduleRow

struct DayScheduleRow: View {
    let day: Weekday
    let schedule: DaySchedule?
    let walkingTime: Int
    let bufferTime: Int
    let hasNotification: Bool
    let onTap: () -> Void
    let onClear: () -> Void
    let onCopy: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme

    init(
        day: Weekday,
        schedule: DaySchedule?,
        walkingTime: Int,
        bufferTime: Int,
        hasNotification: Bool,
        onTap: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onCopy: (() -> Void)? = nil
    ) {
        self.day = day
        self.schedule = schedule
        self.walkingTime = walkingTime
        self.bufferTime = bufferTime
        self.hasNotification = hasNotification
        self.onTap = onTap
        self.onClear = onClear
        self.onCopy = onCopy
    }

    private var leaveTime: String? {
        guard let s = schedule else { return nil }
        let totalMinutes = s.departureHour * 60 + s.departureMinute - walkingTime - bufferTime
        return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    // Day badge - larger and more prominent
                    Text(day.shortName)
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(schedule != nil ? .white : .secondary)
                        .background(
                            Circle()
                                .fill(schedule != nil ? Color
                                    .accentColor :
                                    (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2)))
                        )
                        .overlay(
                            Circle()
                                .stroke(schedule != nil ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 2)
                                .padding(-2)
                        )

                    if let s = schedule {
                        // Schedule details
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                // Train line and time
                                HStack(spacing: 8) {
                                    Text(s.lineNumber)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.lineColor(for: s.lineNumber), in: Capsule())

                                    Text(s.departureTimeString)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)

                                    if s.transfers > 0 {
                                        HStack(spacing: 3) {
                                            Text("\(s.transfers)")
                                            Image(systemName: "arrow.triangle.swap")
                                        }
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.orange)
                                    }
                                }

                                // Leave time and notification
                                HStack(spacing: 8) {
                                    if let leave = leaveTime {
                                        HStack(spacing: 4) {
                                            Image(systemName: "figure.walk")
                                                .font(.caption2)
                                            Text("Leave \(leave)")
                                        }
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.purple, in: Capsule())
                                    }

                                    if hasNotification {
                                        HStack(spacing: 3) {
                                            Image(systemName: "bell.fill")
                                                .font(.caption2)
                                            Text("ON")
                                                .font(.caption2.weight(.semibold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.blue, in: Capsule())
                                    }
                                }
                            }

                            Spacer()
                        }
                    } else {
                        Text("Not set - Tap to add")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 12)
            }
            .tint(.primary)
            .contextMenu {
                if schedule != nil {
                    if let onCopy {
                        Button(action: {
                            Haptics.selection()
                            onCopy()
                        }) {
                            Label("Copy to other days", systemImage: "doc.on.doc")
                        }
                    }

                    Button(action: {
                        Haptics.selection()
                        onTap()
                    }) {
                        Label("Edit", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive, action: {
                        Haptics.notification(.warning)
                        onClear()
                    }) {
                        Label("Clear", systemImage: "trash")
                    }
                }
            }

            if schedule != nil {
                Button(action: {
                    Haptics.impact(.light)
                    onClear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
    }
}

// MARK: - ScheduleEmptyState

struct ScheduleEmptyState: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var animate = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.1))
                    .frame(width: 100, height: 100)
                    .scaleEffect(animate ? 1.1 : 1.0)

                Image(systemName: "tram.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                    .offset(x: animate ? 2 : -2)
            }

            VStack(spacing: 8) {
                Text("Set up your daily commute")
                    .font(.title3.weight(.semibold))

                Text("Select both stations above to get started with your repeat journey schedules")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 32)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

// MARK: - ReadyToScheduleHint

struct ReadyToScheduleHint: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .scaleEffect(pulse ? 1.1 : 1.0)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to set your schedule")
                    .font(.subheadline.weight(.semibold))

                Text("Tap any day below to select your regular train")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - CopyScheduleSheet

struct CopyScheduleSheet: View {
    let sourceDay: Weekday
    let sourceSchedule: DaySchedule?
    let direction: CommuteDirection
    @Binding var route: SavedCommuteRoute
    let onSave: () -> Void
    let onCopied: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDays: Set<Weekday> = []

    private var availableDays: [Weekday] {
        Weekday.mondayFirst.filter { $0 != sourceDay }
    }

    private var preselectedDays: Set<Weekday> {
        // Smart preselection: if source is weekday, select other weekdays
        if [.monday, .tuesday, .wednesday, .thursday, .friday].contains(sourceDay) {
            return Set([.monday, .tuesday, .wednesday, .thursday, .friday].filter { $0 != sourceDay })
        }
        return []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Source info
                VStack(spacing: 12) {
                    Text("Copy \(sourceDay.fullName)'s Schedule")
                        .font(.title3.weight(.semibold))

                    if let schedule = sourceSchedule {
                        HStack(spacing: 8) {
                            Text(schedule.lineNumber)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.lineColor(for: schedule.lineNumber), in: Capsule())

                            Text(schedule.departureTimeString)
                                .font(.body.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray6))
                        )
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 20)
                .background(colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground))

                // Day selection
                List {
                    Section {
                        ForEach(availableDays) { day in
                            let isSelected = selectedDays.contains(day)
                            let hasExisting = route.schedule(for: day, direction: direction) != nil

                            Button(action: {
                                Haptics.selection()
                                if isSelected {
                                    selectedDays.remove(day)
                                } else {
                                    selectedDays.insert(day)
                                }
                            }) {
                                HStack(spacing: 14) {
                                    // Checkbox
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                                    // Day name
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(day.fullName)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)

                                        if hasExisting {
                                            Text("Will replace existing schedule")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }

                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Select days to copy to")
                    } footer: {
                        if !selectedDays.isEmpty {
                            Text("Copying to \(selectedDays.count) day\(selectedDays.count > 1 ? "s" : "")")
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy to \(selectedDays.count) day\(selectedDays.count > 1 ? "s" : "")") {
                        copySchedule()
                    }
                    .disabled(selectedDays.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            selectedDays = preselectedDays
        }
    }

    private func copySchedule() {
        guard let schedule = sourceSchedule else { return }

        for day in selectedDays {
            route.setSchedule(schedule, for: day, direction: direction)
        }

        onSave()
        Haptics.notification(.success)

        // Sort days by weekday order
        let sortedDays = Weekday.mondayFirst.filter { selectedDays.contains($0) }
        let dayNames = sortedDays.map(\.shortName).joined(separator: ", ")
        onCopied("Copied \(sourceDay.shortName) schedule to \(dayNames)")

        dismiss()
    }
}

extension CommuteScheduleView {
    func searchStations(_ query: String) async -> [Station] {
        await (try? TransportService.shared.searchStations(matching: query, transportType: .trainCommute)) ?? []
    }

    func toggleFavorite(_ station: Station) {
        var config = settingsManager.trainCommuteConfig
        config.toggleFavoriteStation(station)
        settingsManager.updateConfig(config)
    }
}

// MARK: - DayTrainPicker

struct DayTrainPicker: View {
    let day: Weekday
    let from: Station
    let to: Station
    let direction: CommuteDirection
    @Binding var route: SavedCommuteRoute
    let onSave: () -> Void
    let onFirstSchedule: (() -> Void)?

    @EnvironmentObject private var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @State private var connections: [TrainConnection] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var selectedConnection: TrainConnection?
    @State private var showDetail: TrainConnection?

    init(
        day: Weekday,
        from: Station,
        to: Station,
        direction: CommuteDirection,
        route: Binding<SavedCommuteRoute>,
        onSave: @escaping () -> Void,
        onFirstSchedule: (() -> Void)? = nil
    ) {
        self.day = day
        self.from = from
        self.to = to
        self.direction = direction
        self._route = route
        self.onSave = onSave
        self.onFirstSchedule = onFirstSchedule
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(day.fullName).font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        Text(from.name).scalableText(minimumScale: 0.8)
                        Image(systemName: "arrow.right").font(.caption)
                        Text(to.name).scalableText(minimumScale: 0.8)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(.systemGroupedBackground))
                if isLoading { List { ForEach(0..<5, id: \.self) { _ in SkeletonTrainRow() } }.listStyle(.plain) }
                else if connections.isEmpty { ContentUnavailableView(
                    "No Trains",
                    systemImage: "tram.fill",
                    description: Text("No trains found")
                ) } else { List { ForEach(connections) { conn in TrainSelectionRow(
                    connection: conn,
                    isSelected: selectedConnection?.id == conn.id,
                    onSelect: { selectedConnection = conn },
                    onDetail: { showDetail = conn }
                ).onAppear { if conn.id == connections.last?.id { loadMore() } } }; if isLoadingMore {
                    SkeletonTrainRow()
                } }.listStyle(.plain) }
            }.navigationTitle("Select Train").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }
                    }; ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveSelection() }.disabled(selectedConnection == nil)
                    }
                }
                .sheet(item: $showDetail) { ConnectionDetailSheet(connection: $0) }
        }.task { await loadConnections() }
    }

    private func loadConnections() async {
        isLoading = true
        connections = await (try? TransportService.shared.fetchConnectionsFromMidnight(
            from: from,
            to: to,
            transportType: .trainCommute
        )) ?? []
        hasMore = connections.count >= 5; isLoading = false; preselectExisting()
    }

    private func loadMore() {
        guard hasMore, !isLoadingMore, let last = connections.last else { return }
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date())!
        guard last.departureTime < endOfDay else { hasMore = false; return }
        isLoadingMore = true
        Task {
            let more = await (try? TransportService.shared.fetchMoreConnections(
                from: from,
                to: to,
                transportType: .trainCommute,
                after: last.departureTime
            )) ?? []
            let today = Calendar.current.startOfDay(for: Date())
            let newConns = more.filter { new in !connections.contains { $0.id == new.id } && Calendar.current.isDate(
                new.departureTime,
                inSameDayAs: today
            ) }
            connections.append(contentsOf: newConns)
            hasMore = more.count >= 5 && (connections.last?.departureTime ?? Date()) < endOfDay
            isLoadingMore = false
        }
    }

    private func preselectExisting() {
        guard let existing = route.schedule(for: day, direction: direction) else { return }
        let calendar = Calendar.current
        selectedConnection = connections
            .first { calendar.component(.hour, from: $0.departureTime) == existing.departureHour && calendar.component(
                .minute,
                from: $0.departureTime
            ) == existing.departureMinute && $0.lineNumber == existing.lineNumber }
    }

    private func saveSelection() {
        guard let conn = selectedConnection else { return }

        // Check if this is the first schedule
        let isFirstSchedule = route.toWorkSchedules.isEmpty && route.toHomeSchedules.isEmpty

        let cal = Calendar.current
        let schedule = DaySchedule(
            lineNumber: conn.lineNumber,
            departureHour: cal.component(.hour, from: conn.departureTime),
            departureMinute: cal.component(.minute, from: conn.departureTime),
            connectionId: conn.id,
            isDailyRepeat: false,
            transfers: conn.transfers
        )
        route.setSchedule(schedule, for: day, direction: direction)
        onSave()

        // Celebrate first schedule
        if isFirstSchedule {
            Haptics.notification(.success)
            onFirstSchedule?()
        }

        // Schedule notifications for this commute
        Task {
            try? await NotificationService.shared.scheduleCommuteNotification(
                route: route,
                day: day,
                schedule: schedule,
                direction: direction,
                config: settingsManager.trainCommuteConfig
            )
        }
        dismiss()
    }
}

// MARK: - SkeletonTrainRow

struct SkeletonTrainRow: View {
    var body: some View {
        HStack(spacing: 14) {
            SkeletonBox(width: 28, height: 28, cornerRadius: 14)
            SkeletonBox(width: 50, height: 36, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SkeletonBox(width: 50, height: 20); SkeletonBox(width: 16, height: 14); SkeletonBox(
                        width: 40,
                        height: 16
                    )
                }
                HStack(spacing: 10) { SkeletonBox(width: 45, height: 14); SkeletonBox(width: 25, height: 14) }
            }
            Spacer()
        }.padding(.vertical, 10).frame(minHeight: 76)
    }
}

// MARK: - TrainSelectionRow

struct TrainSelectionRow: View {
    let connection: TrainConnection; let isSelected: Bool; let onSelect: () -> Void; let onDetail: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.title)
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }.buttonStyle(.plain)
            Text(connection.lineNumber).font(.subheadline.weight(.bold)).foregroundStyle(.white).frame(minWidth: 50)
                .padding(
                    .horizontal,
                    12
                ).padding(.vertical, 8).background(
                    Color.lineColor(for: connection.lineNumber),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(connection.departureTime, style: .time).font(.title3.weight(.medium)); Text("→")
                        .foregroundStyle(.secondary); Text(
                            connection.arrivalTime,
                            style: .time
                        ).font(.body).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text("\(Int(connection.duration / 60)) min").font(.subheadline)
                        .foregroundStyle(.secondary); if connection
                        .transfers >
                        0
                    {
                        Text("\(connection.transfers)×").font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if connection
                .transfers >
                0
            {
                Button(action: onDetail) { Image(systemName: "info.circle").font(.title3).foregroundStyle(.blue) }
                    .buttonStyle(.plain)
            }
        }.padding(.vertical, 10).contentShape(Rectangle()).onTapGesture { onSelect() }
    }
}

#Preview {
    CommuteScheduleView()
        .environmentObject(SettingsManager.shared)
}
