import SwiftUI

// MARK: - CommuteScheduleView

struct CommuteScheduleView: View {
    @StateObject private var viewModel: CommuteScheduleViewModel
    @State private var showFromStationPicker = false
    @State private var showToStationPicker = false
    @State private var selectedDay: Weekday?
    @State private var activeTimingSheet: TimingSheet?
    @State private var showResetConfirm = false
    @State private var showCopySheet: Weekday?
    @State private var showExcludedDatesSheet = false
    @State private var excludedDateSelection: Set<DateComponents> = []
    @State private var suggestions: [CommuteDirection: [Weekday: DaySchedule]] = [:]
    @State private var suggestionLoadingDays: [CommuteDirection: Set<Weekday>] = [:]
    @State private var dismissedSuggestionDays: [CommuteDirection: Set<Weekday>] = [:]
    @State private var suggestionLookupTask: Task<Void, Never>?
    @State private var suggestionLookupGeneration = 0
    @State private var weekendActivationPromptDirection: CommuteDirection?
    @State private var weekendPromptShownDirections: Set<CommuteDirection> = []
    private static let maxConcurrentSuggestionLookups = 3
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var dayChipWidth: CGFloat = 32
    @ScaledMetric(relativeTo: .caption) private var dayChipHeight: CGFloat = 28
    let scrollToTopTrigger: Int

    private let listTopAnchorId = "commute-list-top-anchor"
    private let headerAnchorId = "commute-header-anchor"

    private var directionLabel: String {
        viewModel.selectedDirection == .toWork ? "From → To" : "To → From"
    }

    private var activeRouteLabel: String {
        guard let from = viewModel.currentFromStation?.name, let to = viewModel.currentToStation?.name else {
            return directionLabel
        }
        return "\(from) → \(to)"
    }

    private var spokenActiveRouteLabel: String {
        activeRouteLabel.replacingOccurrences(of: " → ", with: " to ")
    }

    private var directionIcon: String {
        viewModel.selectedDirection == .toWork ? "arrow.right" : "arrow.left"
    }

    private enum CommuteDayPreset {
        case workweek
        case allDays
        case custom

        var title: String {
            switch self {
            case .workweek: "Workweek"
            case .allDays: "All Days"
            case .custom: "Custom"
            }
        }
    }

    private var selectedDirectionActiveDays: Set<Weekday> {
        viewModel.route.activeDays(for: viewModel.selectedDirection)
    }

    private var selectedDirectionPreset: CommuteDayPreset {
        let activeDays = selectedDirectionActiveDays
        if activeDays == Set(Weekday.workweek) { return .workweek }
        if activeDays == Set(Weekday.mondayFirst) { return .allDays }
        return .custom
    }

    init(scrollToTopTrigger: Int = 0) {
        _viewModel = StateObject(wrappedValue: CommuteScheduleViewModel())
        self.scrollToTopTrigger = scrollToTopTrigger
    }

    init(viewModel: CommuteScheduleViewModel, scrollToTopTrigger: Int = 0) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.scrollToTopTrigger = scrollToTopTrigger
    }

    var body: some View {
        VStack(spacing: 0) {
            if !headerScrollsWithList {
                // Full height for the pinned header, so the List gives up space instead of the header's text truncating.
                headerContent
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollViewReader { proxy in
                List {
                    // From XXXL up the header alone can be taller than an SE screen, so it scrolls with the list.
                    if headerScrollsWithList {
                        Section {
                            headerContent
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .buttonStyle(.borderless)
                        }
                        .id(headerAnchorId)
                    }
                    scheduleSection
                        .id(listTopAnchorId)
                    Section {
                        Button("Reset to Defaults", role: .destructive) { showResetConfirm = true }.confirmationDialog(
                            "Reset to Defaults?", isPresented: $showResetConfirm, titleVisibility: .visible
                        ) {
                            Button("Reset", role: .destructive) { viewModel.resetToDefaults() }
                        } message: {
                            Text("This clears your stations, repeat journeys and days off.")
                        }
                    }
                }.onChange(of: scrollToTopTrigger) { _, _ in
                    let topId = headerScrollsWithList ? headerAnchorId : listTopAnchorId
                    withAnimation(.easeInOut) { proxy.scrollTo(topId, anchor: .top) }
                }
            }
        }.background {
            Color.screenBackground(colorScheme).ignoresSafeArea(
                edges: .all)
        }.navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .navigationBar).task {
            viewModel.onAppear()
        }
            .onDisappear { resetAllSuggestions() }
            .onChange(of: viewModel.route.homeStation?.id) { _, _ in resetAllSuggestions() }
            .onChange(of: viewModel.route.workStation?.id) { _, _ in resetAllSuggestions() }
            .onChange(of: viewModel.selectedDirection) { _, _ in
                suggestionLookupTask?.cancel()
                suggestionLookupTask = nil
                suggestionLoadingDays.removeAll()
                dismissedSuggestionDays.removeAll()
            }
            .sheet(isPresented: $showFromStationPicker) {
                stationPicker(
                    title: "From",
                    selection: Binding(
                        get: { viewModel.currentFromStation },
                        set: { viewModel.handleFromStationChange($0) }
                    )
                )
            }.sheet(isPresented: $showToStationPicker) {
                stationPicker(
                    title: "To",
                    selection: Binding(
                        get: { viewModel.currentToStation },
                        set: { viewModel.handleToStationChange($0) }
                    )
                )
            }.sheet(item: $selectedDay) { day in
                if let from = viewModel.currentFromStation, let to = viewModel.currentToStation {
                    DayTrainPicker(
                        day: day, from: from, to: to, direction: viewModel.selectedDirection,
                        route: $viewModel.route,
                        onSave: { viewModel.save() },
                        onScheduleSaved: handleScheduleSaved
                    ) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            viewModel.toastManager.show(
                                "First train saved. Add the rest of your week.", type: .success
                            )
                        }
                    }
                }
            }.sheet(item: $activeTimingSheet) { sheet in
                switch sheet {
                case let .travel(station):
                    TravelTimeSheet(station: station, currentValue: viewModel.config.travelTime(for: station.id)) {
                        time in viewModel.saveTravelTime(time, for: station)
                    }
                case let .buffer(station):
                    BufferTimeSheet(
                        station: station, currentValue: viewModel.config.bufferTime(for: station.id)
                    ) { time in viewModel.saveBufferTime(time, for: station) }
                }
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
            }.sheet(isPresented: $showExcludedDatesSheet) {
                ExcludedDatesSheet(
                    selection: $excludedDateSelection,
                    onSave: {
                        viewModel.updateExcludedDates(dates(from: excludedDateSelection))
                    }
                )
            }
            .confirmationDialog(
                "Add Saturday and Sunday?",
                isPresented: Binding(
                    get: { weekendActivationPromptDirection != nil },
                    set: { if !$0 { weekendActivationPromptDirection = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Add Both Days") {
                    guard let direction = weekendActivationPromptDirection else { return }
                    var activeDays = viewModel.route.activeDays(for: direction)
                    activeDays.formUnion(Weekday.weekend)
                    setActiveDays(activeDays, for: direction)
                    weekendActivationPromptDirection = nil
                    viewModel.toastManager.show("Saturday and Sunday added to your \(direction.title.lowercased()) journeys", type: .success)
                }
                Button("Not Now", role: .cancel) {
                    weekendActivationPromptDirection = nil
                }
            } message: {
                if let direction = weekendActivationPromptDirection {
                    Text("You picked a weekend train for your \(direction.title.lowercased()) journey. Add both Saturday and Sunday?")
                }
            }
            .toastOverlay(viewModel.toastManager)
    }

    private var headerScrollsWithList: Bool { dynamicTypeSize >= .xxxLarge }

    private var headerContent: some View {
        VStack(spacing: 20) {
            // At accessibility sizes the menu moves under the title, so the title gets the full width and wraps between words.
            let titleLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center))
            titleLayout {
                Text("Repeat Journeys").font(.largeTitle.bold())
                    .layoutPriority(1)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                }
                Menu {
                    Button {
                        excludedDateSelection = dateComponentsSet(from: viewModel.excludedDates)
                        showExcludedDatesSheet = true
                    } label: {
                        Label("Days Off", systemImage: "calendar.badge.minus")
                    }

                    if !viewModel.excludedDates.isEmpty {
                        Button(role: .destructive) {
                            excludedDateSelection = []
                            viewModel.updateExcludedDates(dates(from: excludedDateSelection))
                        } label: {
                            Label("Clear Days Off", systemImage: "trash")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "ellipsis.circle")
                            .font(.title2)
                        if !viewModel.excludedDates.isEmpty {
                            Text("\(viewModel.excludedDates.count)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize()
                .padding(.trailing, 4)
                .accessibilityLabel("More options")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RouteHeader(
                startStation: viewModel.currentFromStation,
                endStation: viewModel.currentToStation,
                travelTimeToStart: viewModel.config.travelTime(for: viewModel.currentFromStation?.id),
                bufferTimeToStart: viewModel.config.bufferTime(for: viewModel.currentFromStation?.id),
                onSwap: {
                    viewModel.selectedDirection = viewModel.selectedDirection == .toWork ? .toHome : .toWork
                },
                onStartTap: { showFromStationPicker = true },
                onEndTap: { showToStationPicker = true },
                onSetTravelTime: { station in
                    activeTimingSheet = .travel(station)
                },
                onSetBufferTime: { station in
                    activeTimingSheet = .buffer(station)
                },
                swapIcon: directionIcon,
                swapAccessibilityLabel: "Switch direction",
                swapAccessibilityValue: spokenActiveRouteLabel
            )

            commuteDaysControls

            if viewModel.hasSchedules {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text("Changing a station hides your current trains. Pick the same stations again to bring them back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
            }
        }
        .padding()
    }

    private func stationPicker(title: String, selection: Binding<Station?>) -> some View {
        StationPickerSheet(
            title: title, stations: viewModel.stations, recentStations: viewModel.recentStations,
            favoriteStations: viewModel.favoriteStations,
            searchHandler: { await viewModel.searchStations($0) },
            onToggleFavorite: { viewModel.toggleFavorite($0) },
            selection: selection
        )
        .task { await viewModel.loadStationsIfNeeded() }
    }

    private var commuteDaysControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStackFallingBackToVStack(spacing: 8) {
                Label("Repeat Days", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button {
                        applyPreset(.workweek, for: viewModel.selectedDirection)
                    } label: {
                        HStack {
                            Text("Workweek (Mon to Fri)")
                            if selectedDirectionPreset == .workweek { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        applyPreset(.allDays, for: viewModel.selectedDirection)
                    } label: {
                        HStack {
                            Text("All Days")
                            if selectedDirectionPreset == .allDays { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedDirectionPreset.title).font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
                }
            }

            // An adaptive grid wraps the seven chips onto more rows once the text grows past one row's width.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dayChipWidth), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Weekday.mondayFirst) { day in
                    let isActive = selectedDirectionActiveDays.contains(day)
                    Button {
                        toggleActiveDay(day, for: viewModel.selectedDirection)
                    } label: {
                        Text(day.shortName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isActive ? .white : .secondary)
                            .frame(maxWidth: .infinity, minHeight: dayChipHeight)
                            .background(
                                Capsule().fill(
                                    isActive
                                        ? Color.accentColor
                                        : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.16))
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(day.fullName) \(isActive ? "active" : "inactive")")
                }
            }

            Text("Suggestions and reminders run only on active days.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(
                Color.cardSurface(colorScheme)
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
        )
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
                    let isDayActive = viewModel.route.isDayActive(day, direction: viewModel.selectedDirection)
                    let suggestion = isDayActive ? suggestions[viewModel.selectedDirection]?[day] : nil
                    let isSuggestionLoading =
                        isDayActive
                        && suggestion == nil
                        && suggestionLoadingDays[viewModel.selectedDirection]?.contains(day) == true

                    DayScheduleRow(
                        day: day,
                        isDayActive: isDayActive,
                        schedule: schedule,
                        suggestion: suggestion,
                        isSuggestionLoading: isSuggestionLoading,
                        walkingTime: travelTime, bufferTime: bufferTime,
                        onTap: { selectedDay = day },
                        onEnableDay: !isDayActive ? {
                            var activeDays = viewModel.route.activeDays(for: viewModel.selectedDirection)
                            activeDays.insert(day)
                            setActiveDays(activeDays, for: viewModel.selectedDirection)
                        } : nil,
                        onClear: { handleScheduleCleared(day: day, direction: viewModel.selectedDirection) },
                        onCopy: { showCopySheet = day },
                        onUseSuggestion: { applySuggestion(for: day, direction: viewModel.selectedDirection) },
                        onChooseDifferentSuggestion: {
                            chooseDifferentSuggestion(for: day, direction: viewModel.selectedDirection)
                        },
                        onDismissSuggestion: { dismissSuggestion(for: day, direction: viewModel.selectedDirection) }
                    )
                }
            }
        } header: {
            if viewModel.route.isConfigured {
                Text(activeRouteLabel)
                    .textCase(nil)
                    .accessibilityLabel(spokenActiveRouteLabel)
            }
        }
    }

    private func handleScheduleSaved(day: Weekday, schedule: DaySchedule, direction: CommuteDirection) {
        if day.isWeekend, !weekendPromptShownDirections.contains(direction) {
            let weekendFullyActive = Set(Weekday.weekend).isSubset(of: viewModel.route.activeDays(for: direction))
            if !weekendFullyActive {
                weekendPromptShownDirections.insert(direction)
                weekendActivationPromptDirection = direction
            }
        }
        requestSuggestions(basedOn: schedule, direction: direction, resetDismissedDays: true)
    }

    private func requestSuggestions(
        basedOn schedule: DaySchedule,
        direction: CommuteDirection,
        resetDismissedDays: Bool
    ) {
        cancelSuggestionLookup()
        let lookupGeneration = suggestionLookupGeneration

        if resetDismissedDays {
            dismissedSuggestionDays[direction] = []
        }
        suggestions[direction] = [:]

        let candidates = Weekday.mondayFirst.filter { day in
            viewModel.route.isDayActive(day, direction: direction)
                && viewModel.route.schedule(for: day, direction: direction) == nil
                && !isSuggestionDismissed(day, direction: direction)
        }
        guard !candidates.isEmpty else {
            suggestionLoadingDays[direction] = []
            return
        }
        suggestionLoadingDays[direction] = Set(candidates)

        let scheduleViewModel = viewModel
        suggestionLookupTask = Task(priority: .utility) {
            await withTaskGroup(of: (Weekday, DaySchedule?).self) { group in
                var remainingDays = candidates.makeIterator()
                func startNextLookup() {
                    guard let candidateDay = remainingDays.next() else { return }
                    group.addTask {
                        let matchedSchedule = await scheduleViewModel.findSuggestedSchedule(
                            for: candidateDay,
                            basedOn: schedule,
                            direction: direction
                        )
                        return (candidateDay, matchedSchedule)
                    }
                }
                // A small cap keeps the provider from answering 429 to a burst of trip searches.
                for _ in 0 ..< Self.maxConcurrentSuggestionLookups { startNextLookup() }

                while let (candidateDay, matchedSchedule) = await group.next() {
                    if Task.isCancelled { return }

                    await MainActor.run {
                        guard suggestionLookupGeneration == lookupGeneration else { return }
                        suggestionLoadingDays[direction]?.remove(candidateDay)

                        guard let matchedSchedule else { return }
                        guard scheduleViewModel.route.schedule(for: candidateDay, direction: direction) == nil else { return }
                        guard !isSuggestionDismissed(candidateDay, direction: direction) else { return }

                        suggestions[direction, default: [:]][candidateDay] = matchedSchedule
                    }
                    startNextLookup()
                }
            }

            if Task.isCancelled { return }
            await MainActor.run {
                guard suggestionLookupGeneration == lookupGeneration else { return }
                suggestionLoadingDays[direction] = []
                suggestionLookupTask = nil
            }
        }
    }

    private func handleScheduleCleared(day: Weekday, direction: CommuteDirection) {
        viewModel.clearSchedule(day: day, direction: direction)
        dismissSuggestion(for: day, direction: direction)
        cancelSuggestionLookup()
        suggestionLoadingDays[direction] = []
    }

    /// Bumping the generation makes any in-flight lookup drop its results instead of writing them.
    private func cancelSuggestionLookup() {
        suggestionLookupTask?.cancel()
        suggestionLookupTask = nil
        suggestionLookupGeneration += 1
    }

    private func isSuggestionDismissed(_ day: Weekday, direction: CommuteDirection) -> Bool {
        dismissedSuggestionDays[direction]?.contains(day) == true
    }

    private func resetAllSuggestions() {
        cancelSuggestionLookup()
        suggestions.removeAll()
        suggestionLoadingDays.removeAll()
        dismissedSuggestionDays.removeAll()
    }

    private func dismissSuggestion(for day: Weekday, direction: CommuteDirection) {
        dismissedSuggestionDays[direction, default: []].insert(day)
        suggestionLoadingDays[direction]?.remove(day)
        suggestions[direction]?.removeValue(forKey: day)
    }

    private func applySuggestion(for day: Weekday, direction: CommuteDirection) {
        guard let schedule = suggestions[direction]?[day] else { return }

        viewModel.route.setSchedule(schedule, for: day, direction: direction)
        viewModel.save()
        viewModel.rescheduleAllNotifications()
        dismissSuggestion(for: day, direction: direction)

        viewModel.toastManager.show(
            "\(schedule.lineNumber) set for \(day.fullName).",
            type: .success
        )
    }

    private func chooseDifferentSuggestion(for day: Weekday, direction: CommuteDirection) {
        dismissSuggestion(for: day, direction: direction)
        selectedDay = day
    }

    private func applyPreset(_ preset: CommuteDayPreset, for direction: CommuteDirection) {
        switch preset {
        case .workweek:
            setActiveDays(Set(Weekday.workweek), for: direction)
        case .allDays:
            setActiveDays(Set(Weekday.mondayFirst), for: direction)
        case .custom:
            break
        }
    }

    private func toggleActiveDay(_ day: Weekday, for direction: CommuteDirection) {
        var activeDays = viewModel.route.activeDays(for: direction)
        let isActive = activeDays.contains(day)
        let hasSchedule = viewModel.route.schedule(for: day, direction: direction) != nil

        if isActive {
            if hasSchedule {
                viewModel.toastManager.show("Clear \(day.fullName)'s train first to turn the day off.", type: .info)
                return
            }
            if activeDays.count <= 1 {
                viewModel.toastManager.show("Keep at least one day active.", type: .info)
                return
            }
            activeDays.remove(day)
        } else {
            activeDays.insert(day)
        }

        setActiveDays(activeDays, for: direction)
    }

    private func setActiveDays(_ days: Set<Weekday>, for direction: CommuteDirection) {
        cancelSuggestionLookup()
        suggestionLoadingDays[direction] = []
        viewModel.route.setActiveDays(days, for: direction)
        viewModel.save()
        viewModel.rescheduleAllNotifications()
        clearInactiveSuggestionState(for: direction)
    }

    private func clearInactiveSuggestionState(for direction: CommuteDirection) {
        let inactiveDays = Set(Weekday.mondayFirst).subtracting(viewModel.route.activeDays(for: direction))
        guard !inactiveDays.isEmpty else { return }

        suggestions[direction] = suggestions[direction]?.filter { !inactiveDays.contains($0.key) }
        suggestionLoadingDays[direction]?.subtract(inactiveDays)
        dismissedSuggestionDays[direction]?.subtract(inactiveDays)
    }

    private func dateComponentsSet(from dates: [Date]) -> Set<DateComponents> {
        let calendar = Calendar.current
        return Set(dates.map { calendar.dateComponents([.year, .month, .day], from: $0) })
    }

    private func dates(from components: Set<DateComponents>) -> [Date] {
        let calendar = Calendar.current
        return components.compactMap { calendar.date(from: $0) }.sorted()
    }
}

private struct ExcludedDatesSheet: View {
    @Binding var selection: Set<DateComponents>
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick your days off. Repeat journeys and suggestions skip them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    MultiDatePicker(
                        "Days off",
                        selection: $selection,
                        in: Date()...
                    )
                    .padding(.horizontal, 12)
                }
                .padding(.top, 12)
            }
            .navigationTitle("Days Off")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - DayScheduleRow

struct DayScheduleRow: View {
    let day: Weekday
    let isDayActive: Bool
    let schedule: DaySchedule?
    let suggestion: DaySchedule?
    let isSuggestionLoading: Bool
    let walkingTime: Int
    let bufferTime: Int
    let onTap: () -> Void
    let onEnableDay: (() -> Void)?
    let onClear: () -> Void
    let onCopy: () -> Void
    let onUseSuggestion: () -> Void
    let onChooseDifferentSuggestion: () -> Void
    let onDismissSuggestion: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var dayBadgeSize: CGFloat = 36
    private let badgeToContentSpacing: CGFloat = 14

    init(
        day: Weekday,
        isDayActive: Bool,
        schedule: DaySchedule?,
        suggestion: DaySchedule?,
        isSuggestionLoading: Bool,
        walkingTime: Int,
        bufferTime: Int,
        onTap: @escaping () -> Void,
        onEnableDay: (() -> Void)?,
        onClear: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onUseSuggestion: @escaping () -> Void,
        onChooseDifferentSuggestion: @escaping () -> Void,
        onDismissSuggestion: @escaping () -> Void
    ) {
        self.day = day
        self.isDayActive = isDayActive
        self.schedule = schedule
        self.suggestion = suggestion
        self.isSuggestionLoading = isSuggestionLoading
        self.walkingTime = walkingTime
        self.bufferTime = bufferTime
        self.onTap = onTap
        self.onEnableDay = onEnableDay
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
    private var isInactiveWithoutSchedule: Bool {
        !isDayActive && schedule == nil && suggestion == nil && !isSuggestionLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isShowingSuggestion ? 2 : 8) {
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
        let badgeAndContentLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: badgeToContentSpacing))
        return Button(action: onTap) {
            badgeAndContentLayout {
                dayBadge
                scheduleContent
            }
            .padding(.vertical, isShowingSuggestionOrLoading ? 4 : (isInactiveWithoutSchedule ? 7 : 12))
        }
        .opacity(isInactiveWithoutSchedule ? 0.84 : 1.0)
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
            .frame(width: dayBadgeSize, height: dayBadgeSize)
            .foregroundStyle(isActive ? .white : .secondary)
            .background(Circle().fill(bgColor))
            .overlay(Circle().stroke(strokeColor, lineWidth: 2).padding(-2))
    }

    @ViewBuilder
    private var scheduleContent: some View {
        if let s = schedule {
            scheduleDetailsView(s)
        } else if isInactiveWithoutSchedule {
            inactiveDayView
        } else if let suggested = suggestion {
            suggestionPreviewView(suggested)
        } else if isSuggestionLoading {
            suggestionLoadingView
        } else {
            Text("No train yet. Tap to add one.").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var suggestionLoadingView: some View {
        HStack(spacing: 8) {
            SkeletonBox(width: 60, height: 28, cornerRadius: 14)
            SkeletonBox(width: 72, height: 22, cornerRadius: 8)
            SkeletonBox(width: 96, height: 18, cornerRadius: 8)
            Spacer()
        }
        .skeletonShimmer()
    }

    private var inactiveDayView: some View {
        HStackFallingBackToVStack(spacing: 8) {
            Text("Inactive day")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let onEnableDay {
                Button {
                    Haptics.selection()
                    onEnableDay()
                } label: {
                    Text("Turn On")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Turn on \(day.fullName)")
            }
            Text("Tap to pick a train")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionPreviewView(_ s: DaySchedule) -> some View {
        HStackFallingBackToVStack(spacing: 8) {
            ScheduleLineBadge(schedule: s, horizontalPadding: 8, verticalPadding: 4)

            Text(s.departureTimeString)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

            Text("Suggested")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.repeatSuggestionText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scheduleDetailsView(_ s: DaySchedule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            trainLineRow(s)
            leaveTimeRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trainLineRow(_ s: DaySchedule) -> some View {
        HStackFallingBackToVStack(spacing: 8) {
            ScheduleLineBadge(schedule: s, horizontalPadding: 8, verticalPadding: 4)

            Text(s.departureTimeString)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

            if s.transfers > 0 {
                HStack(spacing: 3) {
                    Text("\(s.transfers)")
                    Image(systemName: "arrow.triangle.branch")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(changeCountLabel(s.transfers))
            }
        }
    }

    private var leaveTimeRow: some View {
        HStackFallingBackToVStack(spacing: 8) {
            if let leave = leaveTime {
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk").font(.caption2)
                    Text("Leave \(leave)")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.repeatLeaveChip, in: Capsule())
            }

            if schedule != nil {
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill").font(.caption2)
                    Text("On").font(.caption2.weight(.semibold))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reminder on")
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.repeatNotificationChip, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if schedule != nil {
            Button { Haptics.selection(); onCopy() } label: {
                Label("Copy to Other Days", systemImage: "doc.on.doc")
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
                .accessibilityLabel("Clear \(day.fullName)'s train")
        }
    }

    private var suggestionActionRow: some View {
        HStack {
            HStack(spacing: 18) {
                suggestionButton(
                    systemImage: "checkmark.circle.fill", font: .title3.weight(.semibold), style: .green,
                    accessibilityLabel: "Use suggested train", action: onUseSuggestion
                )
                suggestionButton(
                    systemImage: "xmark.circle.fill", font: .title3.weight(.semibold), style: .orange,
                    accessibilityLabel: "Pick another train", action: onChooseDifferentSuggestion
                )
            }

            Spacer()

            suggestionButton(
                systemImage: "minus.circle.fill", font: .title3, style: .secondary,
                accessibilityLabel: "Hide suggestion", action: onDismissSuggestion
            )
        }
        .padding(.leading, 50)
        .padding(.top, -6)
    }

    private func suggestionButton<S: ShapeStyle>(
        systemImage: String, font: Font, style: S, accessibilityLabel: String, action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(style)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - ScheduleLineBadge

private struct ScheduleLineBadge: View {
    let schedule: DaySchedule
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    var body: some View {
        let style = Color.lineBadgeStyle(for: schedule.lineNumber, apiColors: schedule.lineColors)
        Text(schedule.lineNumber)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(style.background, in: Capsule())
    }
}

// MARK: - ScheduleEmptyState

struct ScheduleEmptyState: View {
    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .title3) private var haloSize: CGFloat = 100
    @ScaledMetric(relativeTo: .title3) private var tramIconSize: CGFloat = 40
    @State private var animate = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.1)).frame(
                    width: haloSize, height: haloSize
                ).scaleEffect(animate ? 1.1 : 1.0)

                Image(systemName: "tram.fill").font(.system(size: tramIconSize)).foregroundStyle(Color.accentColor)
                    .offset(x: animate ? 2 : -2)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Set up a repeat journey").font(.title3.weight(.semibold))

                Text("Pick your start and destination stations above.").font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 32)
            .modifier(RepeatingIdleMotion(isAnimating: $animate, animation: .easeInOut(duration: 2)))
    }
}

// MARK: - ReadyToScheduleHint

struct ReadyToScheduleHint: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pulse = false

    var body: some View {
        let iconAndTextLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        iconAndTextLayout {
            Image(systemName: "calendar.badge.plus").font(.title2).foregroundStyle(Color.accentColor).scaleEffect(
                pulse ? 1.1 : 1.0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to pick your trains").font(.subheadline.weight(.semibold))

                Text("Tap a day below to pick your usual train.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(
            RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.08))
        ).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.2), lineWidth: 1)).padding(
            .horizontal, 16
        ).padding(.bottom, 8).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            .modifier(RepeatingIdleMotion(isAnimating: $pulse, animation: .easeInOut(duration: 1.5)))
    }
}

// MARK: - RepeatingIdleMotion

/// Runs an autoreversing idle animation while the view is on screen and holds it still under Reduce Motion.
private struct RepeatingIdleMotion: ViewModifier {
    @Binding var isAnimating: Bool
    let animation: Animation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear(perform: start)
            .onDisappear(perform: stop)
            .onChange(of: reduceMotion) { _, _ in
                stop()
                start()
            }
    }

    private func start() {
        guard !reduceMotion else { return }
        withAnimation(animation.repeatForever(autoreverses: true)) { isAnimating = true }
    }

    private func stop() {
        withTransaction(Transaction(animation: nil)) { isAnimating = false }
    }
}

// MARK: - HStackFallingBackToVStack

/// Lays its children out in a row when they fit on one line, otherwise in a column, so no text has to break mid-word.
struct HStackFallingBackToVStack<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing, content: content)
            VStack(alignment: alignment, spacing: spacing, content: content)
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
                    Text("Copy \(sourceDay.fullName)'s Train").font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)

                    if let schedule = sourceSchedule {
                        HStack(spacing: 8) {
                            ScheduleLineBadge(schedule: schedule, horizontalPadding: 10, verticalPadding: 5)

                            Text(schedule.departureTimeString).font(.body.weight(.medium))
                        }.padding(.horizontal, 16).padding(.vertical, 10).background(
                            RoundedRectangle(cornerRadius: 12).fill(
                                colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray6)))
                    }
                }.padding(.vertical, 20).padding(.horizontal, 20).background(
                    Color.screenBackground(colorScheme))

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
                                            Text("Replaces the train already set").font(.caption).foregroundStyle(
                                                .orange)
                                        }
                                    }

                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    } header: {
                        Text("Pick Days").textCase(nil)
                    } footer: {
                        if !selectedDays.isEmpty {
                            Text("Copying to \(selectedDays.count) \(selectedDays.count == 1 ? "day" : "days")")
                        }
                    }
                }
            }.navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy to \(selectedDays.count) \(selectedDays.count == 1 ? "Day" : "Days")") { copySchedule() }
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
        onCopied("Copied \(sourceDay.shortName) train to \(dayNames)")

        dismiss()
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
    @State private var paginationSeedDateTime = Date()
    @State private var forwardCursor: String?
    /// The calendar day being configured. Timetables are day-of-week specific, so the
    /// search runs against the next occurrence of `day`, not against today.
    private var serviceDay: Date { day.nextOccurrence() }

    private var serviceDayWindow: DateInterval {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: serviceDay)
        return DateInterval(start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
    }

    init(
        day: Weekday, from: Station, to: Station, direction: CommuteDirection,
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
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text(from.name)
                            Image(systemName: "arrow.right").font(.caption)
                            Text(to.name)
                        }
                        VStack(spacing: 4) {
                            Text(from.name)
                            Image(systemName: "arrow.down").font(.caption)
                            Text(to.name)
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(from.name) to \(to.name)")
                }.frame(maxWidth: .infinity).padding(.vertical, 16).padding(.horizontal).background(
                    Color(.systemGroupedBackground))
                if isLoading {
                    List { ForEach(0 ..< 5, id: \.self) { _ in SkeletonTrainRow() } }.listStyle(.plain)
                } else if connections.isEmpty {
                    ContentUnavailableView("No connections", systemImage: "tram.fill", description: Text("Nothing found for \(day.fullName). Close this and try again."))
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
            }.navigationTitle("Pick a Train").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSelection() }.disabled(selectedConnection == nil)
                }
            }.sheet(item: $showDetail) { ConnectionDetailSheet(connection: $0) }
        }.task { await loadConnections() }
    }

    private func loadConnections() async {
        isLoading = true

        let calendar = Calendar.current
        let window = serviceDayWindow
        let dayStart = window.start
        let dayEnd = window.end

        // Seed before the first useful departure rather than at midnight. A
        // midnight-anchored search spends its whole first response on night trains:
        // for Stadlau to Graz that was 23:57 through 05:36, putting every morning
        // departure two round trips out of reach.
        paginationSeedDateTime = calendar.date(byAdding: .hour, value: 4, to: dayStart) ?? dayStart

        let result = try? await transportService.fetchConnectionsCovering(
            from: from,
            to: to,
            seedDateTime: paginationSeedDateTime,
            coverage: ConnectionCoverage(
                minimumCount: Self.initialConnectionTarget,
                throughDeparture: calendar.date(byAdding: .hour, value: 9, to: dayStart),
                notBefore: dayStart,
                notAfter: dayEnd
            ),
            onPage: { page in
                await MainActor.run {
                    appendPage(page)
                    isLoading = false
                }
            }
        )

        if let result {
            connections = result.connections
            forwardCursor = result.forwardCursor
        }
        hasMore = forwardCursor != nil && (connections.last?.departureTime ?? dayStart) < dayEnd
        isLoading = false
        preselectExisting()
    }

    /// Merges a page into the list without disturbing what is already on screen, and says whether it added any.
    @discardableResult
    private func appendPage(_ page: [TrainConnection]) -> Bool {
        let existingIds = Set(connections.map(\.id))
        let additions = page.filter { !existingIds.contains($0.id) }
        guard !additions.isEmpty else { return false }
        connections.append(contentsOf: additions)
        connections.sort { $0.departureTime < $1.departureTime }
        return true
    }

    /// Roughly two pages' worth. The provider caps a response at six or seven trips, so
    /// this plus the 09:00 coverage target lands the whole morning without paying for
    /// the much slower third and fourth pages up front.
    private static let initialConnectionTarget = 12

    private func loadMore(remainingHops: Int = FetchLimits.maxCoveragePages) {
        guard remainingHops > 0, hasMore, !isLoadingMore, let last = connections.last else { return }
        let window = serviceDayWindow
        let dayStart = window.start
        let dayEnd = window.end
        guard forwardCursor != nil, last.departureTime < dayEnd else {
            hasMore = false
            return
        }
        isLoadingMore = true
        Task {
            guard let cursor = forwardCursor,
                  let page = try? await transportService.fetchConnectionsPage(
                      from: from,
                      to: to,
                      seedDateTime: paginationSeedDateTime,
                      pageSize: FetchLimits.connectionBatchSize,
                      cursor: cursor
                  )
            else {
                // No usable cursor means no reliable way to continue this day's search.
                // The departure-seeded fallback restarts the search and returns pages
                // that overlap what is already shown, which stalled paging outright.
                forwardCursor = nil
                hasMore = false
                isLoadingMore = false
                return
            }

            let nextCursor = page.forwardCursor
            forwardCursor = (nextCursor != nil && nextCursor != cursor) ? nextCursor : nil

            let addedConnections = appendPage(
                page.connections.filter { $0.departureTime >= dayStart && $0.departureTime < dayEnd }
            )

            // A page whose results were all filtered out leaves `connections.last`
            // unchanged, so the list's onAppear trigger never fires again. Keep paging
            // from here instead of waiting for a scroll that will not come.
            let exhaustedDay = page.connections.contains { $0.departureTime >= dayEnd }
            hasMore = forwardCursor != nil && !exhaustedDay
            isLoadingMore = false
            if hasMore, !addedConnections { loadMore(remainingHops: remainingHops - 1) }
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

        // Reconcile rather than scheduling this one entry directly: occurrences are
        // dated, so the whole set has to be replanned against the saved route.
        Task { await CommuteNotificationReconciler.reconcile(notificationService: notificationService) }
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
        }.skeletonShimmer().padding(.vertical, 10).frame(minHeight: 76)
    }
}

// MARK: - TrainSelectionRow

struct TrainSelectionRow: View {
    let connection: TrainConnection
    let isSelected: Bool
    let onSelect: () -> Void
    let onDetail: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        selectButton
                        lineBadge
                        Spacer(minLength: 8)
                        detailButton
                    }
                    timesAndStats
                }
            } else {
                HStack(spacing: 14) {
                    selectButton
                    lineBadge
                    timesAndStats
                    Spacer(minLength: 8)
                    detailButton
                }
            }
        }.padding(.vertical, 10).contentShape(Rectangle()).onTapGesture { onSelect() }
    }

    private var selectButton: some View {
        Button(action: onSelect) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.title).foregroundStyle(
                isSelected ? .blue : .secondary)
        }.buttonStyle(.plain)
    }

    private var lineBadge: some View {
        let style = Color.lineBadgeStyle(for: connection.lineNumber, apiColors: connection.lineColors)
        return Text(connection.lineNumber)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(style.foreground)
            .frame(minWidth: 50)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(style.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var detailButton: some View {
        Button(action: onDetail) { Image(systemName: "info.circle").font(.title3).foregroundStyle(.blue) }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection details")
    }

    private var timesAndStats: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStackFallingBackToVStack(spacing: 8) {
                Text(connection.departureTime, style: .time).font(.title3.weight(.medium))
                Text("→").foregroundStyle(.secondary).accessibilityLabel("to")
                Text(connection.arrivalTime, style: .time).font(.body).foregroundStyle(.secondary)
            }
            HStackFallingBackToVStack(spacing: 10) {
                let durationMinutes = Int(connection.duration / 60)
                Text("\(durationMinutes) min").font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityLabel(durationMinutes == 1 ? "1 minute" : "\(durationMinutes) minutes")
                if let stops = connection.totalStopCount, stops > 0 {
                    Text("\(stops) \(stops == 1 ? "stop" : "stops")").font(.subheadline).foregroundStyle(.blue)
                }
                if connection.transfers > 0 {
                    HStack(spacing: 3) {
                        Text("\(connection.transfers)")
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(changeCountLabel(connection.transfers))
                }
            }
        }
    }
}

/// What VoiceOver reads for a change count badge, for example "1 change" or "2 changes".
private func changeCountLabel(_ count: Int) -> String {
    count == 1 ? "1 change" : "\(count) changes"
}

#Preview {
    CommuteScheduleView()
        .environmentObject(SettingsManager.shared)
}
