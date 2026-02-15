import CoreLocation
import SwiftUI

// MARK: - CommuteScheduleView

struct CommuteScheduleView: View {
    @StateObject private var viewModel: CommuteScheduleViewModel
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var locationService: LocationService
    @State private var showStationAPicker = false
    @State private var showStationBPicker = false
    @State private var selectedDay: Weekday?
    @State private var showTravelTimeSheet: Station?
    @State private var showBufferTimeSheet: Station?
    @State private var showResetConfirm = false
    @State private var pulseHint = false
    @State private var showCopySheet: Weekday?
    @State private var toWorkSuggestions: [Weekday: DaySchedule] = [:]
    @State private var toHomeSuggestions: [Weekday: DaySchedule] = [:]
    @State private var toWorkSuggestionLoadingDays: Set<Weekday> = []
    @State private var toHomeSuggestionLoadingDays: Set<Weekday> = []
    @State private var toWorkDismissedSuggestionDays: Set<Weekday> = []
    @State private var toHomeDismissedSuggestionDays: Set<Weekday> = []
    @State private var suggestionLookupTask: Task<Void, Never>?
    @State private var suggestionLookupGeneration = 0
    @Environment(\.colorScheme) var colorScheme

    private var autoPreferredStationIds: Set<String> {
        Set(settingsManager.appSettings.autoSelectionPreferences.areaPreferences.map(\.stationId))
    }

    private var autoExcludedStationIds: Set<String> {
        settingsManager.appSettings.autoSelectionPreferences.excludedStationIds
    }

    init(transportType: TransportType = .trainCommute) {
        _viewModel = StateObject(wrappedValue: CommuteScheduleViewModel(transportType: transportType))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Repeat Journeys").font(.largeTitle.bold())
                Spacer()
            }.padding(.horizontal).padding(.top, 13).padding(.bottom, 12)

            List {
                stationsSection
                directionPicker
                if viewModel.currentFromStation != nil { travelTimeSection }
                scheduleSection
                Section {
                    Button("Reset to Defaults", role: .destructive) { showResetConfirm = true }.confirmationDialog(
                        "Reset to Defaults?", isPresented: $showResetConfirm, titleVisibility: .visible
                    ) {
                        Button("Reset All Settings", role: .destructive) { viewModel.resetToDefaults() }
                    } message: {
                        Text("This will clear all stations, schedules, and reset timing to defaults.")
                    }
                }
            }
        }.background {
            (colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)).ignoresSafeArea(
                edges: .all)
        }.navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .navigationBar).task {
            viewModel.onAppear()
        }.onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulseHint = true }
        }
            .onDisappear {
                pulseHint = false
                resetAllSuggestions()
            }
            .onChange(of: viewModel.route.homeStation?.id) { _, _ in resetAllSuggestions() }
            .onChange(of: viewModel.route.workStation?.id) { _, _ in resetAllSuggestions() }
            .onChange(of: viewModel.selectedDirection) { _, _ in
                suggestionLookupTask?.cancel()
                suggestionLookupTask = nil
                clearAllSuggestionLoading()
                clearAllDismissedSuggestions()
            }
            .sheet(isPresented: $showStationAPicker) {
                StationPickerSheet(
                    title: "Station A", stations: viewModel.stations, recentStations: viewModel.recentStations,
                    favoriteStations: viewModel.favoriteStations,
                    nearbyStations: viewModel.nearbyStationService.nearbyStations,
                    stationDistances: viewModel.nearbyStationService.stationDistances,
                    autoSelection: StationPickerAutoSelectionOptions(
                        preferredStationIds: autoPreferredStationIds,
                        excludedStationIds: autoExcludedStationIds,
                        onSetPreferred: setPreferredAutoStation,
                        onToggleExcluded: toggleAutoExcludedStation
                    ),
                    searchHandler: { await viewModel.searchStations($0) },
                    onToggleFavorite: { viewModel.toggleFavorite($0) },
                    selection: Binding(
                        get: { viewModel.route.homeStation },
                        set: { viewModel.handleStationAChange($0) }
                    )
                )
                .task { await viewModel.loadStationsIfNeeded() }
            }.sheet(isPresented: $showStationBPicker) {
                StationPickerSheet(
                    title: "Station B", stations: viewModel.stations, recentStations: viewModel.recentStations,
                    favoriteStations: viewModel.favoriteStations,
                    nearbyStations: viewModel.nearbyStationService.nearbyStations,
                    stationDistances: viewModel.nearbyStationService.stationDistances,
                    autoSelection: StationPickerAutoSelectionOptions(
                        preferredStationIds: autoPreferredStationIds,
                        excludedStationIds: autoExcludedStationIds,
                        onSetPreferred: setPreferredAutoStation,
                        onToggleExcluded: toggleAutoExcludedStation
                    ),
                    searchHandler: { await viewModel.searchStations($0) },
                    onToggleFavorite: { viewModel.toggleFavorite($0) },
                    selection: Binding(
                        get: { viewModel.route.workStation },
                        set: { viewModel.handleStationBChange($0) }
                    )
                )
                .task { await viewModel.loadStationsIfNeeded() }
            }.sheet(item: $selectedDay) { day in
                if let from = viewModel.currentFromStation, let to = viewModel.currentToStation {
                    DayTrainPicker(
                        day: day, from: from, to: to, direction: viewModel.selectedDirection,
                        transportType: viewModel.transportType, route: $viewModel.route,
                        onSave: { viewModel.save() },
                        onScheduleSaved: handleScheduleSaved
                    ) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            viewModel.toastManager.show(
                                "Great start! Keep going to complete your week", type: .success
                            )
                        }
                    }
                }
            }.sheet(item: $showTravelTimeSheet) { station in
                TravelTimeSheet(
                    station: station, currentValue: viewModel.config.travelTime(for: station.id),
                    suggestedValue: viewModel.nearbyStationService.suggestedTravelTimeMinutes(for: station.id)
                ) { time in viewModel.saveTravelTime(time, for: station) }
            }.sheet(item: $showBufferTimeSheet) { station in
                BufferTimeSheet(
                    station: station, currentValue: viewModel.config.bufferTime(for: station.id)
                ) { time in viewModel.saveBufferTime(time, for: station) }
            }.sheet(item: $showCopySheet) { day in
                CopyScheduleSheet(
                    sourceDay: day,
                    sourceSchedule: viewModel.route.schedule(for: day, direction: viewModel.selectedDirection),
                    direction: viewModel.selectedDirection, route: $viewModel.route,
                    onSave: {
                        viewModel.save()
                        viewModel.rescheduleAllNotifications()
                    },
                    onCopied: { message in viewModel.toastManager.show(message, type: .success) }
                )
            }
            .toastOverlay(viewModel.toastManager)
    }

    private func setPreferredAutoStation(_ station: Station) {
        guard let location = locationService.currentLocation else {
            viewModel.toastManager.show("Location unavailable. Try again while location is active.", type: .info)
            return
        }

        settingsManager.setPreferredAutoSelectionStation(station, at: location)
        viewModel.toastManager.show("Will prefer \(station.name) for auto-select near this area.", type: .success)
    }

    private func toggleAutoExcludedStation(_ station: Station) {
        let isNowExcluded = settingsManager.toggleAutoSelectionExclusion(for: station)
        let message = isNowExcluded
            ? "\(station.name) will no longer be auto-selected."
            : "\(station.name) can now be auto-selected."
        viewModel.toastManager.show(message, type: .info)
    }

    private var stationsSection: some View {
        Section {
            VStack(spacing: 0) {
                LargeStationCard(label: "A", station: viewModel.route.homeStation, color: .green) {
                    showStationAPicker = true
                }
                .padding(.horizontal, 16).padding(.top, 12)

                RouteVisualizer(
                    fromStation: viewModel.route.homeStation, toStation: viewModel.route.workStation,
                    direction: viewModel.selectedDirection
                ).padding(.vertical, 4)

                LargeStationCard(label: "B", station: viewModel.route.workStation, color: .red) {
                    showStationBPicker = true
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }

            if viewModel.hasSchedules {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
                        Text("Changing stations will archive your current schedules").font(.subheadline)
                            .foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).padding(.vertical, 12).background(
                        RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
                    Spacer()
                }.padding(.horizontal, 16)
            }
        }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
    }

    private var directionPicker: some View {
        Section {
            Picker("Direction", selection: $viewModel.selectedDirection) {
                Text("A → B").tag(CommuteDirection.toWork)
                Text("B → A").tag(CommuteDirection.toHome)
            }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(
                EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
    }

    private var travelTimeSection: some View {
        Section("Timing for \(viewModel.selectedDirection == .toWork ? "A → B" : "B → A")") {
            let fromStation = viewModel.currentFromStation
            let travelTime = fromStation.flatMap { viewModel.config.travelTime(for: $0.id) }
            let suggestedTravelTime = fromStation.flatMap {
                viewModel.nearbyStationService.suggestedTravelTimeMinutes(for: $0.id)
            }
            let bufferTime = fromStation.flatMap { viewModel.config.bufferTime(for: $0.id) }
            if let time = travelTime {
                HStack {
                    Label("\(time) min to station", systemImage: "figure.walk")
                    Spacer()
                    if let station = fromStation { Button("Edit") { showTravelTimeSheet = station }.font(.subheadline) }
                }
            } else if let suggested = suggestedTravelTime, let station = fromStation {
                HStack {
                    Label("Suggested \(suggested) min", systemImage: "sparkles").foregroundStyle(.blue)
                    Spacer()
                    Button("Use") { viewModel.saveTravelTime(suggested, for: station) }.font(.subheadline)
                    Button("Edit") { showTravelTimeSheet = station }.font(.subheadline)
                }
            } else if let station = fromStation {
                Button {
                    showTravelTimeSheet = station
                } label: {
                    HStack {
                        Label("Set travel time to \(station.name)", systemImage: "plus.circle.fill").opacity(
                            pulseHint ? 0.7 : 1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if let buffer = bufferTime {
                HStack {
                    Label("\(buffer) min buffer", systemImage: "clock.badge.checkmark").foregroundStyle(.orange)
                    Spacer()
                    if let station = fromStation { Button("Edit") { showBufferTimeSheet = station }.font(.subheadline) }
                }
            } else if let station = fromStation {
                Button {
                    showBufferTimeSheet = station
                } label: {
                    HStack {
                        Label("Set buffer time", systemImage: "plus.circle.fill").foregroundStyle(.orange).opacity(
                            pulseHint ? 0.7 : 1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            if !viewModel.route.isConfigured {
                ScheduleEmptyState()
            } else {
                let fromStation = viewModel.currentFromStation
                let travelTime = fromStation.flatMap { viewModel.config.travelTime(for: $0.id) } ?? 0
                let bufferTime = fromStation.flatMap { viewModel.config.bufferTime(for: $0.id) } ?? 0
                let hasAnySchedule = viewModel.hasSchedules

                if !hasAnySchedule { ReadyToScheduleHint() }

                ForEach(Weekday.mondayFirst) { day in
                    let schedule = viewModel.route.schedule(for: day, direction: viewModel.selectedDirection)
                    let hasSchedule = schedule != nil
                    let suggestion = suggestion(for: day, direction: viewModel.selectedDirection)
                    let isSuggestionLoading =
                        suggestion == nil && suggestionLoading(for: day, direction: viewModel.selectedDirection)

                    DayScheduleRow(
                        day: day,
                        schedule: schedule,
                        suggestion: suggestion,
                        isSuggestionLoading: isSuggestionLoading,
                        walkingTime: travelTime, bufferTime: bufferTime, hasNotification: hasSchedule,
                        onTap: { selectedDay = day },
                        onClear: { handleScheduleCleared(day: day, direction: viewModel.selectedDirection) },
                        onCopy: hasSchedule ? { showCopySheet = day } : nil,
                        onUseSuggestion: suggestion != nil
                            ? { applySuggestion(for: day, direction: viewModel.selectedDirection) }
                            : nil,
                        onChooseDifferentSuggestion: suggestion != nil
                            ? { chooseDifferentSuggestion(for: day, direction: viewModel.selectedDirection) }
                            : nil,
                        onDismissSuggestion: suggestion != nil
                            ? { dismissSuggestion(for: day, direction: viewModel.selectedDirection) }
                            : nil
                    )
                }
            }
        } header: {
            if viewModel.route.isConfigured {
                Text("Schedule for \(viewModel.selectedDirection == .toWork ? "A → B" : "B → A")")
            }
        }
    }

    private func handleScheduleSaved(day _: Weekday, schedule: DaySchedule, direction: CommuteDirection) {
        requestSuggestions(basedOn: schedule, direction: direction)
    }

    private func requestSuggestions(basedOn schedule: DaySchedule, direction: CommuteDirection) {
        suggestionLookupTask?.cancel()
        suggestionLookupTask = nil
        suggestionLookupGeneration += 1
        let lookupGeneration = suggestionLookupGeneration

        clearDismissedSuggestions(for: direction)
        clearSuggestions(for: direction)

        let candidates = Weekday.mondayFirst.filter { day in
            viewModel.route.schedule(for: day, direction: direction) == nil
                && !isSuggestionDismissed(day, direction: direction)
        }
        guard !candidates.isEmpty else {
            clearSuggestionLoading(for: direction)
            return
        }
        setSuggestionLoading(Set(candidates), for: direction)

        suggestionLookupTask = Task(priority: .utility) {
            for candidateDay in candidates {
                if Task.isCancelled { return }
                let matchedSchedule = await viewModel.findSuggestedSchedule(
                    for: candidateDay,
                    basedOn: schedule,
                    direction: direction
                )

                await MainActor.run {
                    guard suggestionLookupGeneration == lookupGeneration else { return }
                    removeSuggestionLoading(for: candidateDay, direction: direction)
                    guard let matchedSchedule else { return }
                    guard viewModel.route.schedule(for: candidateDay, direction: direction) == nil else { return }
                    guard !isSuggestionDismissed(candidateDay, direction: direction) else { return }
                    switch direction {
                    case .toWork: toWorkSuggestions[candidateDay] = matchedSchedule
                    case .toHome: toHomeSuggestions[candidateDay] = matchedSchedule
                    }
                }
            }

            if Task.isCancelled { return }

            await MainActor.run {
                guard suggestionLookupGeneration == lookupGeneration else { return }
                clearSuggestionLoading(for: direction)
                suggestionLookupTask = nil
            }
        }
    }

    private func handleScheduleCleared(day: Weekday, direction: CommuteDirection) {
        viewModel.clearSchedule(day: day, direction: direction)
        dismissSuggestion(for: day, direction: direction)
        removeSuggestionLoading(for: day, direction: direction)

        guard let template = firstScheduleTemplate(for: direction) else {
            clearSuggestions(for: direction)
            clearSuggestionLoading(for: direction)
            return
        }
        requestSuggestions(basedOn: template, direction: direction)
    }

    private func suggestion(for day: Weekday, direction: CommuteDirection) -> DaySchedule? {
        switch direction {
        case .toWork: return toWorkSuggestions[day]
        case .toHome: return toHomeSuggestions[day]
        }
    }

    private func setSuggestions(_ suggestions: [Weekday: DaySchedule], for direction: CommuteDirection) {
        switch direction {
        case .toWork: toWorkSuggestions = suggestions
        case .toHome: toHomeSuggestions = suggestions
        }
    }

    private func clearSuggestions(for direction: CommuteDirection) {
        setSuggestions([:], for: direction)
    }

    private func suggestionLoading(for day: Weekday, direction: CommuteDirection) -> Bool {
        switch direction {
        case .toWork: return toWorkSuggestionLoadingDays.contains(day)
        case .toHome: return toHomeSuggestionLoadingDays.contains(day)
        }
    }

    private func setSuggestionLoading(_ loadingDays: Set<Weekday>, for direction: CommuteDirection) {
        switch direction {
        case .toWork: toWorkSuggestionLoadingDays = loadingDays
        case .toHome: toHomeSuggestionLoadingDays = loadingDays
        }
    }

    private func removeSuggestionLoading(for day: Weekday, direction: CommuteDirection) {
        switch direction {
        case .toWork: toWorkSuggestionLoadingDays.remove(day)
        case .toHome: toHomeSuggestionLoadingDays.remove(day)
        }
    }

    private func clearSuggestionLoading(for direction: CommuteDirection) {
        setSuggestionLoading([], for: direction)
    }

    private func dismissedSuggestionDays(for direction: CommuteDirection) -> Set<Weekday> {
        switch direction {
        case .toWork: return toWorkDismissedSuggestionDays
        case .toHome: return toHomeDismissedSuggestionDays
        }
    }

    private func isSuggestionDismissed(_ day: Weekday, direction: CommuteDirection) -> Bool {
        dismissedSuggestionDays(for: direction).contains(day)
    }

    private func setDismissedSuggestionDays(_ days: Set<Weekday>, for direction: CommuteDirection) {
        switch direction {
        case .toWork: toWorkDismissedSuggestionDays = days
        case .toHome: toHomeDismissedSuggestionDays = days
        }
    }

    private func markSuggestionDismissed(_ day: Weekday, direction: CommuteDirection) {
        switch direction {
        case .toWork: toWorkDismissedSuggestionDays.insert(day)
        case .toHome: toHomeDismissedSuggestionDays.insert(day)
        }
    }

    private func clearDismissedSuggestions(for direction: CommuteDirection) {
        setDismissedSuggestionDays([], for: direction)
    }

    private func clearAllDismissedSuggestions() {
        toWorkDismissedSuggestionDays.removeAll()
        toHomeDismissedSuggestionDays.removeAll()
    }

    private func clearAllSuggestionLoading() {
        toWorkSuggestionLoadingDays.removeAll()
        toHomeSuggestionLoadingDays.removeAll()
    }

    private func resetAllSuggestions() {
        suggestionLookupTask?.cancel()
        suggestionLookupTask = nil
        suggestionLookupGeneration += 1
        toWorkSuggestions.removeAll()
        toHomeSuggestions.removeAll()
        clearAllSuggestionLoading()
        clearAllDismissedSuggestions()
    }

    private func dismissSuggestion(for day: Weekday, direction: CommuteDirection) {
        markSuggestionDismissed(day, direction: direction)
        removeSuggestionLoading(for: day, direction: direction)
        switch direction {
        case .toWork: toWorkSuggestions.removeValue(forKey: day)
        case .toHome: toHomeSuggestions.removeValue(forKey: day)
        }
    }

    private func firstScheduleTemplate(for direction: CommuteDirection) -> DaySchedule? {
        for day in Weekday.mondayFirst {
            if let schedule = viewModel.route.schedule(for: day, direction: direction) {
                return schedule
            }
        }
        return nil
    }

    private func applySuggestion(for day: Weekday, direction: CommuteDirection) {
        guard let schedule = suggestion(for: day, direction: direction) else { return }

        viewModel.route.setSchedule(schedule, for: day, direction: direction)
        viewModel.save()
        viewModel.rescheduleAllNotifications()
        dismissSuggestion(for: day, direction: direction)

        viewModel.toastManager.show(
            "Applied \(schedule.lineNumber) to \(day.fullName).",
            type: .success
        )
    }

    private func chooseDifferentSuggestion(for day: Weekday, direction: CommuteDirection) {
        dismissSuggestion(for: day, direction: direction)
        selectedDay = day
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
        Button(action: { Haptics.impact(.light); onTap() }) {
            cardContent
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        .simultaneousGesture(pressGesture)
        .accessibilityLabel("Station \(label): \(station?.name ?? "Not selected")")
        .accessibilityHint("Tap to select station \(label)")
    }

    // MARK: - Subviews

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            stationContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(color: shadowColor, radius: 12, y: 4)
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text("Station \(label)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }

    @ViewBuilder
    private var stationContent: some View {
        if let station {
            selectedStationView(station)
        } else {
            emptyStateView
        }
    }

    private func selectedStationView(_ station: Station) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(station.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .scalableText(minimumScale: 0.7)

            if !station.lines.isEmpty {
                lineBadgesView(station.lines)
            }
        }
    }

    private func lineBadgesView(_ lines: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(lines.prefix(5)), id: \.self) { line in
                    Text(line)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.lineColor(for: line), in: Capsule())
                }
                if lines.count > 5 {
                    Text("+\(lines.count - 5)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    private var emptyStateView: some View {
        let promptText: String = label == "A" ? "starting point" : "destination"
        let hintText: String = label == "A" ? "Choose your home/work station" : "Choose your destination station"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tap to select \(promptText)")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: "hand.tap.fill").font(.caption)
                Text(hintText).font(.caption)
            }
            .foregroundStyle(.tertiary)
        }
    }

    private var cardBackground: some View {
        let fillColor: Color = colorScheme == .dark ? Color(.secondarySystemBackground) : .white
        return RoundedRectangle(cornerRadius: 16).fill(fillColor)
    }

    private var cardBorder: some View {
        let strokeColor: Color = station != nil
            ? color.opacity(0.3)
            : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2))
        let lineWidth: CGFloat = station != nil ? 2 : 1
        return RoundedRectangle(cornerRadius: 16).stroke(strokeColor, lineWidth: lineWidth)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .clear : .black.opacity(0.06)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in isPressed = true }
            .onEnded { _ in isPressed = false }
    }
}

// MARK: - RouteVisualizer

struct RouteVisualizer: View {
    let fromStation: Station?
    let toStation: Station?
    let direction: CommuteDirection
    @State private var pulseAnimation = false
    @Environment(\.colorScheme) var colorScheme

    var showArrow: Bool { fromStation != nil || toStation != nil }

    var rotationAngle: Double { direction == .toHome ? 180 : 0 }

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                ForEach(0 ..< 3) { i in
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(
                        showArrow ? Color.accentColor : Color.secondary.opacity(0.3)
                    ).opacity(pulseAnimation ? 0.3 : 1.0).animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true).delay(Double(i) * 0.2),
                        value: pulseAnimation
                    )
                }
            }.frame(height: 28).rotationEffect(.degrees(rotationAngle)).animation(
                .spring(response: 0.6, dampingFraction: 0.7), value: rotationAngle
            ).onAppear { pulseAnimation = true }
            Spacer()
        }
    }
}

// MARK: - DayScheduleRow

struct DayScheduleRow: View {
    let day: Weekday
    let schedule: DaySchedule?
    let suggestion: DaySchedule?
    let isSuggestionLoading: Bool
    let walkingTime: Int
    let bufferTime: Int
    let hasNotification: Bool
    let onTap: () -> Void
    let onClear: () -> Void
    let onCopy: (() -> Void)?
    let onUseSuggestion: (() -> Void)?
    let onChooseDifferentSuggestion: (() -> Void)?
    let onDismissSuggestion: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme

    init(
        day: Weekday,
        schedule: DaySchedule?,
        suggestion: DaySchedule? = nil,
        isSuggestionLoading: Bool = false,
        walkingTime: Int,
        bufferTime: Int,
        hasNotification: Bool,
        onTap: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onCopy: (() -> Void)? = nil,
        onUseSuggestion: (() -> Void)? = nil,
        onChooseDifferentSuggestion: (() -> Void)? = nil,
        onDismissSuggestion: (() -> Void)? = nil
    ) {
        self.day = day
        self.schedule = schedule
        self.suggestion = suggestion
        self.isSuggestionLoading = isSuggestionLoading
        self.walkingTime = walkingTime
        self.bufferTime = bufferTime
        self.hasNotification = hasNotification
        self.onTap = onTap
        self.onClear = onClear
        self.onCopy = onCopy
        self.onUseSuggestion = onUseSuggestion
        self.onChooseDifferentSuggestion = onChooseDifferentSuggestion
        self.onDismissSuggestion = onDismissSuggestion
    }

    private var leaveTime: String? {
        guard let s = schedule else { return nil }
        let totalMinutes: Int = s.departureHour * 60 + s.departureMinute - walkingTime - bufferTime
        return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private var isShowingSuggestion: Bool { schedule == nil && suggestion != nil }
    private var isShowingSuggestionOrLoading: Bool { isShowingSuggestion || (schedule == nil && isSuggestionLoading) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                mainButton
                clearButton
            }

            if isShowingSuggestion {
                suggestionActionRow
            }
        }
    }

    // MARK: - Subviews

    private var mainButton: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                dayBadge
                scheduleContent
            }
            .padding(.vertical, isShowingSuggestionOrLoading ? 8 : 12)
        }
        .tint(.primary)
        .contextMenu { contextMenuContent }
    }

    private var dayBadge: some View {
        let isActive: Bool = schedule != nil
        let bgColor: Color = isActive
            ? Color.accentColor
            : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2))
        let strokeColor: Color = isActive ? Color.accentColor.opacity(0.3) : Color.clear

        return Text(day.shortName)
            .font(.subheadline.weight(.bold))
            .frame(width: 36, height: 36)
            .foregroundStyle(isActive ? .white : .secondary)
            .background(Circle().fill(bgColor))
            .overlay(Circle().stroke(strokeColor, lineWidth: 2).padding(-2))
    }

    @ViewBuilder
    private var scheduleContent: some View {
        if let s = schedule {
            scheduleDetailsView(s)
        } else if let suggested = suggestion {
            suggestionPreviewView(suggested)
        } else if isSuggestionLoading {
            suggestionLoadingView
        } else {
            Text("Not set - Tap to add").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var suggestionLoadingView: some View {
        HStack(spacing: 8) {
            SkeletonBox(width: 44, height: 22, cornerRadius: 11)
            SkeletonBox(width: 56, height: 18, cornerRadius: 6)
            SkeletonBox(width: 70, height: 14, cornerRadius: 6)
            Spacer()
        }
    }

    private func suggestionPreviewView(_ s: DaySchedule) -> some View {
        let style = Color.lineBadgeStyle(for: s.lineNumber, apiColors: s.lineColors)
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(s.lineNumber)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(style.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(style.background, in: Capsule())
                    .overlay {
                        if let border = style.border {
                            Capsule().stroke(border.opacity(0.7), lineWidth: 1)
                        }
                    }

                Text(s.departureTimeString)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Text("Suggested")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    private func scheduleDetailsView(_ s: DaySchedule) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                trainLineRow(s)
                leaveTimeRow
            }
            Spacer()
        }
    }

    private func trainLineRow(_ s: DaySchedule) -> some View {
        let style = Color.lineBadgeStyle(for: s.lineNumber, apiColors: s.lineColors)
        return HStack(spacing: 8) {
            Text(s.lineNumber)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(style.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(style.background, in: Capsule())
                .overlay {
                    if let border = style.border {
                        Capsule().stroke(border.opacity(0.7), lineWidth: 1)
                    }
                }

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
    }

    private var leaveTimeRow: some View {
        HStack(spacing: 8) {
            if let leave = leaveTime {
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk").font(.caption2)
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
                    Image(systemName: "bell.fill").font(.caption2)
                    Text("ON").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.blue, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if schedule != nil {
            if let onCopy {
                Button { Haptics.selection(); onCopy() } label: {
                    Label("Copy to other days", systemImage: "doc.on.doc")
                }
            }
            Button { Haptics.selection(); onTap() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) { Haptics.notification(.warning); onClear() } label: {
                Label("Clear", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        if schedule != nil {
            Button {
                Haptics.impact(.light)
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(.leading, 8)
        }
    }

    @ViewBuilder
    private var suggestionActionRow: some View {
        HStack(spacing: 10) {
            if let onUseSuggestion {
                Button {
                    Haptics.selection()
                    onUseSuggestion()
                }
                label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Accept suggested train")
            }

            if let onChooseDifferentSuggestion {
                Button {
                    Haptics.selection()
                    onChooseDifferentSuggestion()
                }
                label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deny suggestion and choose another train")
            }

            Spacer()

            if let onDismissSuggestion {
                Button {
                    Haptics.selection()
                    onDismissSuggestion()
                }
                label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss suggestion")
            }
        }
        .padding(.leading, 50)
        .padding(.bottom, 4)
    }
}

// MARK: - ScheduleEmptyState

struct ScheduleEmptyState: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var animate = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.1)).frame(
                    width: 100, height: 100
                ).scaleEffect(animate ? 1.1 : 1.0)

                Image(systemName: "tram.fill").font(.system(size: 40)).foregroundStyle(Color.accentColor).offset(
                    x: animate ? 2 : -2)
            }

            VStack(spacing: 8) {
                Text("Set up your daily commute").font(.title3.weight(.semibold))

                Text("Select both stations above to get started with your repeat journey schedules").font(.subheadline)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 32).onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { animate = true }
        }
    }
}

// MARK: - ReadyToScheduleHint

struct ReadyToScheduleHint: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus").font(.title2).foregroundStyle(Color.accentColor).scaleEffect(
                pulse ? 1.1 : 1.0)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to set your schedule").font(.subheadline.weight(.semibold))

                Text("Tap any day below to select your regular train").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }.padding(16).background(
            RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.08))
        ).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.2), lineWidth: 1)).padding(
            .horizontal, 16
        ).padding(.bottom, 8).listRowInsets(EdgeInsets()).listRowBackground(Color.clear).onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { pulse = true }
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

    private var availableDays: [Weekday] { Weekday.mondayFirst.filter { $0 != sourceDay } }

    private var preselectedDays: Set<Weekday> {
        if [.monday, .tuesday, .wednesday, .thursday, .friday].contains(sourceDay) {
            return Set([.monday, .tuesday, .wednesday, .thursday, .friday].filter { $0 != sourceDay })
        }
        return []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Text("Copy \(sourceDay.fullName)'s Schedule").font(.title3.weight(.semibold))

                    if let schedule = sourceSchedule {
                        let style = Color.lineBadgeStyle(for: schedule.lineNumber, apiColors: schedule.lineColors)
                        HStack(spacing: 8) {
                            Text(schedule.lineNumber)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(style.foreground)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(style.background, in: Capsule())
                                .overlay {
                                    if let border = style.border {
                                        Capsule().stroke(border.opacity(0.7), lineWidth: 1)
                                    }
                                }

                            Text(schedule.departureTimeString).font(.body.weight(.medium))
                        }.padding(.horizontal, 16).padding(.vertical, 10).background(
                            RoundedRectangle(cornerRadius: 12).fill(
                                colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray6)))
                    }
                }.padding(.vertical, 20).padding(.horizontal, 20).background(
                    colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground))

                List {
                    Section {
                        ForEach(availableDays) { day in
                            let isSelected = selectedDays.contains(day)
                            let hasExisting = route.schedule(for: day, direction: direction) != nil

                            Button(action: {
                                Haptics.selection()
                                if isSelected { selectedDays.remove(day) } else { selectedDays.insert(day) }
                            }) {
                                HStack(spacing: 14) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.title2)
                                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(day.fullName).font(.body.weight(.medium)).foregroundStyle(.primary)

                                        if hasExisting {
                                            Text("Will replace existing schedule").font(.caption).foregroundStyle(
                                                .orange)
                                        }
                                    }

                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    } header: {
                        Text("Select days to copy to")
                    } footer: {
                        if !selectedDays.isEmpty {
                            Text("Copying to \(selectedDays.count) day\(selectedDays.count > 1 ? "s" : "")")
                        }
                    }
                }
            }.navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy to \(selectedDays.count) day\(selectedDays.count > 1 ? "s" : "")") { copySchedule() }
                        .disabled(selectedDays.isEmpty).fontWeight(.semibold)
                }
            }
        }.presentationDetents([.medium, .large]).onAppear { selectedDays = preselectedDays }
    }

    private func copySchedule() {
        guard let schedule = sourceSchedule else { return }

        for day in selectedDays {
            route.setSchedule(schedule, for: day, direction: direction)
        }

        onSave()
        Haptics.notification(.success)

        let sortedDays = Weekday.mondayFirst.filter { selectedDays.contains($0) }
        let dayNames = sortedDays.map(\.shortName).joined(separator: ", ")
        onCopied("Copied \(sourceDay.shortName) schedule to \(dayNames)")

        dismiss()
    }
}

// MARK: - DayTrainPicker

struct DayTrainPicker: View {
    let day: Weekday
    let from: Station
    let to: Station
    let direction: CommuteDirection
    let transportType: TransportType
    @Binding var route: SavedCommuteRoute
    let onSave: () -> Void
    let onScheduleSaved: ((Weekday, DaySchedule, CommuteDirection) -> Void)?
    let onFirstSchedule: (() -> Void)?

    private let transportService: TransportServiceProtocol
    private let notificationService: NotificationServiceProtocol

    @EnvironmentObject private var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @State private var connections: [TrainConnection] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var selectedConnection: TrainConnection?
    @State private var showDetail: TrainConnection?

    init(
        day: Weekday, from: Station, to: Station, direction: CommuteDirection,
        transportType: TransportType = .trainCommute,
        transportService: TransportServiceProtocol = TransportService.shared,
        notificationService: NotificationServiceProtocol = NotificationService.shared,
        route: Binding<SavedCommuteRoute>,
        onSave: @escaping () -> Void,
        onScheduleSaved: ((Weekday, DaySchedule, CommuteDirection) -> Void)? = nil,
        onFirstSchedule: (() -> Void)? = nil
    ) {
        self.day = day
        self.from = from
        self.to = to
        self.direction = direction
        self.transportType = transportType
        self.transportService = transportService
        self.notificationService = notificationService
        _route = route
        self.onSave = onSave
        self.onScheduleSaved = onScheduleSaved
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
                    }.font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 16).background(Color(.systemGroupedBackground))
                if isLoading {
                    List { ForEach(0 ..< 5, id: \.self) { _ in SkeletonTrainRow() } }.listStyle(.plain)
                } else if connections.isEmpty {
                    ContentUnavailableView("No Trains", systemImage: "tram.fill", description: Text("No trains found"))
                } else {
                    List {
                        ForEach(connections) { conn in
                            TrainSelectionRow(
                                connection: conn, isSelected: selectedConnection?.id == conn.id,
                                onSelect: { selectedConnection = conn }, onDetail: { showDetail = conn }
                            ).onAppear { if conn.id == connections.last?.id { loadMore() } }
                        }
                        if isLoadingMore { SkeletonTrainRow() }
                    }.listStyle(.plain)
                }
            }.navigationTitle("Select Train").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSelection() }.disabled(selectedConnection == nil)
                }
            }.sheet(item: $showDetail) { ConnectionDetailSheet(connection: $0) }
        }.task { await loadConnections() }
    }

    private func loadConnections() async {
        isLoading = true
        connections =
            await
                (try? transportService.fetchConnectionsFromMidnight(
                    from: from,
                    to: to,
                    transportType: transportType
                ))
                ?? []
        hasMore = connections.count >= 5
        isLoading = false
        preselectExisting()
    }

    private func loadMore() {
        guard hasMore, !isLoadingMore, let last = connections.last else { return }
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date())!
        guard last.departureTime < endOfDay else {
            hasMore = false
            return
        }
        isLoadingMore = true
        Task {
            let more =
                await
                    (try? transportService.fetchMoreConnections(
                        from: from, to: to, transportType: transportType, after: last.departureTime
                    )) ?? []
            let today = Calendar.current.startOfDay(for: Date())
            let newConns = more.filter { new in
                !connections.contains { $0.id == new.id }
                    && Calendar.current.isDate(new.departureTime, inSameDayAs: today)
            }
            connections.append(contentsOf: newConns)
            hasMore = more.count >= 5 && (connections.last?.departureTime ?? Date()) < endOfDay
            isLoadingMore = false
        }
    }

    private func preselectExisting() {
        guard let existing = route.schedule(for: day, direction: direction) else { return }
        let calendar = Calendar.current
        selectedConnection = connections.first {
            calendar.component(.hour, from: $0.departureTime) == existing.departureHour
                && calendar.component(.minute, from: $0.departureTime) == existing.departureMinute
                && $0.lineNumber == existing.lineNumber
        }
    }

    private func saveSelection() {
        guard let conn = selectedConnection else { return }

        let isFirstSchedule = route.toWorkSchedules.isEmpty && route.toHomeSchedules.isEmpty

        let cal = Calendar.current
        let schedule = DaySchedule(
            lineNumber: conn.lineNumber, lineColors: conn.lineColors,
            departureHour: cal.component(.hour, from: conn.departureTime),
            departureMinute: cal.component(.minute, from: conn.departureTime), connectionId: conn.id,
            isDailyRepeat: false, transfers: conn.transfers
        )
        route.setSchedule(schedule, for: day, direction: direction)
        onSave()
        onScheduleSaved?(day, schedule, direction)

        if isFirstSchedule {
            Haptics.notification(.success)
            onFirstSchedule?()
        }

        Task {
            try? await notificationService.scheduleCommuteNotification(
                route: route, day: day, schedule: schedule, direction: direction,
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
                    SkeletonBox(width: 50, height: 20)
                    SkeletonBox(width: 16, height: 14)
                    SkeletonBox(width: 40, height: 16)
                }
                HStack(spacing: 10) {
                    SkeletonBox(width: 45, height: 14)
                    SkeletonBox(width: 25, height: 14)
                }
            }
            Spacer()
        }.padding(.vertical, 10).frame(minHeight: 76)
    }
}

// MARK: - TrainSelectionRow

struct TrainSelectionRow: View {
    let connection: TrainConnection
    let isSelected: Bool
    let onSelect: () -> Void
    let onDetail: () -> Void

    var body: some View {
        let style = Color.lineBadgeStyle(for: connection.lineNumber, apiColors: connection.lineColors)
        HStack(spacing: 14) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.title).foregroundStyle(
                    isSelected ? .blue : .secondary)
            }.buttonStyle(.plain)
            Text(connection.lineNumber)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(style.foreground)
                .frame(minWidth: 50)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(style.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if let border = style.border {
                        RoundedRectangle(cornerRadius: 8).stroke(border.opacity(0.7), lineWidth: 1)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(connection.departureTime, style: .time).font(.title3.weight(.medium))
                    Text("→").foregroundStyle(.secondary)
                    Text(connection.arrivalTime, style: .time).font(.body).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text("\(Int(connection.duration / 60)) min").font(.subheadline).foregroundStyle(.secondary)
                    if let stops = connection.totalStopCount, stops > 0 {
                        Text("\(stops) stops").font(.subheadline).foregroundStyle(.blue)
                    }
                    if connection.transfers > 0 {
                        Text("\(connection.transfers)×").font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button(action: onDetail) { Image(systemName: "info.circle").font(.title3).foregroundStyle(.blue) }
                .buttonStyle(.plain)
        }.padding(.vertical, 10).contentShape(Rectangle()).onTapGesture { onSelect() }
    }
}

#Preview {
    CommuteScheduleView(transportType: .trainCommute)
        .environmentObject(SettingsManager.shared)
        .environmentObject(LocationService.shared)
}
