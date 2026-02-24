import Foundation

@MainActor
final class CommuteScheduleViewModel: ObservableObject {
    // MARK: - Published State

    @Published var route: SavedCommuteRoute = .init()
    @Published var stations: [Station] = []
    @Published var selectedDirection: CommuteDirection = .toWork

    let toastManager = ToastManager()

    // MARK: - Dependencies

    let transportType: TransportType
    private let transportService: TransportServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let settingsManager: SettingsManager
    private let searchService: StationSearchService
    private var hasLoadedStations = false
    private var isLoadingStations = false

    // MARK: - Computed

    var config: RouteConfiguration { settingsManager.config(for: transportType) }
    var currentFromStation: Station? { selectedDirection == .toWork ? route.homeStation : route.workStation }
    var currentToStation: Station? { selectedDirection == .toWork ? route.workStation : route.homeStation }
    var hasSchedules: Bool { !route.toWorkSchedules.isEmpty || !route.toHomeSchedules.isEmpty }
    var recentStations: [Station] { config.recentStations }
    var favoriteStations: [Station] { config.favoriteStations }

    // MARK: - Init

    init(
        transportType: TransportType = .trainCommute,
        transportService: TransportServiceProtocol = TransportService.shared,
        notificationService: NotificationServiceProtocol = NotificationService.shared,
        settingsManager: SettingsManager? = nil
    ) {
        self.transportType = transportType
        self.transportService = transportService
        self.notificationService = notificationService
        self.settingsManager = settingsManager ?? SettingsManager.shared
        searchService = StationSearchService(transportService: transportService)
    }

    // MARK: - Lifecycle

    func onAppear() { route = settingsManager.savedCommuteRoute }

    func loadStationsIfNeeded() async {
        if hasLoadedStations { return }

        guard !isLoadingStations else { return }
        isLoadingStations = true
        defer { isLoadingStations = false }

        do {
            stations = try await transportService.fetchStations(for: transportType)
            hasLoadedStations = true
        } catch {
            return
        }
    }

    // MARK: - Station Search

    func searchStations(_ query: String) async -> [Station] {
        await searchService.searchStations(query, transportType: transportType)
    }

    // MARK: - Favorites

    func toggleFavorite(_ station: Station) {
        settingsManager.toggleFavoriteStation(station, for: transportType)
    }

    // MARK: - Timing

    func saveTravelTime(_ minutes: Int?, for station: Station) {
        settingsManager.saveTravelTime(minutes, for: station.id, transportType: transportType)
    }

    func saveBufferTime(_ minutes: Int?, for station: Station) {
        settingsManager.saveBufferTime(minutes, for: station.id, transportType: transportType)
    }

    // MARK: - Station Changes

    func handleFromStationChange(_ newStation: Station?) {
        let old = (route.homeStation, route.workStation)
        switch selectedDirection {
        case .toWork:
            settingsManager.handleStationChange(
                oldStart: old.0,
                oldEnd: old.1,
                newStart: newStation,
                newEnd: old.1
            )
        case .toHome:
            settingsManager.handleStationChange(
                oldStart: old.0,
                oldEnd: old.1,
                newStart: old.0,
                newEnd: newStation
            )
        }
        route = settingsManager.savedCommuteRoute
        rescheduleAllNotifications()
    }

    func handleToStationChange(_ newStation: Station?) {
        let old = (route.homeStation, route.workStation)
        switch selectedDirection {
        case .toWork:
            settingsManager.handleStationChange(
                oldStart: old.0,
                oldEnd: old.1,
                newStart: old.0,
                newEnd: newStation
            )
        case .toHome:
            settingsManager.handleStationChange(
                oldStart: old.0,
                oldEnd: old.1,
                newStart: newStation,
                newEnd: old.1
            )
        }
        route = settingsManager.savedCommuteRoute
        rescheduleAllNotifications()
    }

    // MARK: - Schedule Management

    func save() {
        settingsManager.updateSavedCommuteRoute(route)
    }

    func clearSchedule(day: Weekday, direction: CommuteDirection) {
        notificationService.cancelCommuteNotification(day: day, direction: direction)
        route.removeSchedule(for: day, direction: direction)
        save()
        toastManager.show("Cleared \(day.fullName) schedule", type: .info)
    }

    func updateExcludedDates(_ dates: [Date]) {
        let calendar = Calendar.current
        route.skippedDates = dates
            .map { calendar.startOfDay(for: $0) }
            .sorted()
        route.pruneOldSkippedDates()
        save()
    }

    var excludedDates: [Date] {
        route.skippedDates.sorted()
    }

    func resetToDefaults() {
        Haptics.notification(.warning)
        route = SavedCommuteRoute()
        save()
    }

    func findSuggestedSchedule(
        for day: Weekday,
        basedOn template: DaySchedule,
        direction: CommuteDirection
    ) async -> DaySchedule? {
        guard let from = route.fromStation(for: direction), let to = route.toStation(for: direction) else { return nil }
        guard let departure = suggestionSearchStart(for: day, template: template) else { return nil }

        guard let connections = try? await transportService.fetchConnections(
            from: from,
            to: to,
            transportType: transportType,
            departureTime: departure,
            count: FetchLimits.commuteSuggestionConnectionCount
        ) else { return nil }

        return bestSuggestedSchedule(in: connections, template: template)
    }

    func findSuggestedSchedules(
        for days: [Weekday],
        basedOn template: DaySchedule,
        direction: CommuteDirection
    ) async -> [Weekday: DaySchedule] {
        var suggestions: [Weekday: DaySchedule] = [:]
        for day in days {
            if Task.isCancelled { return suggestions }
            if let suggestion = await findSuggestedSchedule(
                for: day,
                basedOn: template,
                direction: direction
            ) {
                suggestions[day] = suggestion
            }
        }

        return suggestions
    }

    // MARK: - Notifications

    func rescheduleAllNotifications() {
        Task {
            notificationService.cancelAllCommuteNotifications()
            let cfg = config
            for (day, schedule) in route.toWorkSchedules {
                try? await notificationService.scheduleCommuteNotification(
                    route: route, day: day, schedule: schedule, direction: .toWork, config: cfg
                )
            }
            for (day, schedule) in route.toHomeSchedules {
                try? await notificationService.scheduleCommuteNotification(
                    route: route, day: day, schedule: schedule, direction: .toHome, config: cfg
                )
            }
        }
    }

    // MARK: - Private

    private func suggestionSearchStart(for day: Weekday, template: DaySchedule) -> Date? {
        var components = DateComponents()
        components.weekday = day.rawValue
        components.hour = template.departureHour
        components.minute = template.departureMinute
        components.second = 0

        guard let departure = Calendar.current.nextDate(
            after: Date().addingTimeInterval(-60),
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else { return nil }

        return departure.addingTimeInterval(-45 * 60)
    }

    private func bestSuggestedSchedule(in connections: [TrainConnection], template: DaySchedule) -> DaySchedule? {
        let eligibleConnections = connections.filter { $0.status != .cancelled }
        guard !eligibleConnections.isEmpty else { return nil }

        if let templateConnectionId = template.connectionId,
           let matchingId = eligibleConnections.first(where: { $0.id == templateConnectionId })
        {
            return makeSchedule(from: matchingId)
        }

        if let exact = eligibleConnections.first(where: { connectionMatchesTemplate($0, template: template) }) {
            return makeSchedule(from: exact)
        }

        let normalizedTemplateLine = normalizeLine(template.lineNumber)
        let templateMinutes = template.departureHour * 60 + template.departureMinute
        let calendar = Calendar.current

        let sameLineMatches: [(TrainConnection, Int)] = eligibleConnections.compactMap { connection in
            guard normalizeLine(connection.lineNumber) == normalizedTemplateLine else { return nil }
            let hour = calendar.component(.hour, from: connection.departureTime)
            let minute = calendar.component(.minute, from: connection.departureTime)
            let diff = abs((hour * 60 + minute) - templateMinutes)
            guard diff <= 45 else { return nil }
            return (connection, diff)
        }
        if let sameLineClosest = sameLineMatches.min(by: { $0.1 < $1.1 }).map({ $0.0 }) {
            return makeSchedule(from: sameLineClosest)
        }

        let sameTimeMatches: [(TrainConnection, Int)] = eligibleConnections.compactMap { connection in
            let hour = calendar.component(.hour, from: connection.departureTime)
            let minute = calendar.component(.minute, from: connection.departureTime)
            let diff = abs((hour * 60 + minute) - templateMinutes)
            guard diff <= 30 else { return nil }
            return (connection, diff)
        }
        if let sameTimeClosest = sameTimeMatches.min(by: { $0.1 < $1.1 }).map({ $0.0 }) {
            return makeSchedule(from: sameTimeClosest)
        }

        return makeSchedule(from: eligibleConnections[0])
    }

    private func connectionMatchesTemplate(_ connection: TrainConnection, template: DaySchedule) -> Bool {
        let calendar = Calendar.current
        return normalizeLine(connection.lineNumber) == normalizeLine(template.lineNumber)
            && calendar.component(.hour, from: connection.departureTime) == template.departureHour
            && calendar.component(.minute, from: connection.departureTime) == template.departureMinute
    }

    private func makeSchedule(from connection: TrainConnection) -> DaySchedule {
        let calendar = Calendar.current
        return DaySchedule(
            lineNumber: connection.lineNumber,
            lineColors: connection.lineColors,
            departureHour: calendar.component(.hour, from: connection.departureTime),
            departureMinute: calendar.component(.minute, from: connection.departureTime),
            connectionId: connection.id,
            isDailyRepeat: false,
            transfers: connection.transfers
        )
    }

    private func normalizeLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

}
