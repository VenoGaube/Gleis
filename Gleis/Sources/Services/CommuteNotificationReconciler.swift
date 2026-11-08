import Foundation

// MARK: - CommuteOccurrencePlanner

/// Works out when a weekly commute schedule next actually fires.
///
/// Repeat schedules used to be registered as a single repeating weekly trigger.
/// That could not express "not this Tuesday": a repeating trigger has no way to
/// drop one occurrence, so a skipped date still rang. Planning concrete dated
/// occurrences instead makes skips expressible, and removes the weekday/midnight
/// wraparound arithmetic that hand-rolled minute offsets needed.
enum CommuteOccurrencePlanner {
    struct Occurrence {
        let departureDate: Date
        let leaveDate: Date
    }

    /// The next `limit` firings of this schedule that are not skipped.
    static func upcomingOccurrences(
        route: SavedCommuteRoute,
        day: Weekday,
        schedule: DaySchedule,
        direction: CommuteDirection,
        config: RouteConfiguration,
        referenceDate: Date,
        limit: Int
    ) -> [Occurrence] {
        guard limit > 0, let fromStation = route.fromStation(for: direction) else { return [] }

        let calendar = Calendar.current
        let travel = config.travelTime(for: fromStation.id) ?? config.walkingTimeMinutes
        let buffer = config.bufferTime(for: fromStation.id) ?? config.bufferTimeMinutes
        let leadMinutes = travel + buffer

        var components = DateComponents()
        components.weekday = day.rawValue
        components.hour = schedule.departureHour
        components.minute = schedule.departureMinute
        components.second = 0

        var occurrences: [Occurrence] = []
        var searchFrom = referenceDate
        // Bounded so a schedule skipped far into the future can't spin.
        let maximumWeeksScanned = limit + 8

        for _ in 0 ..< maximumWeeksScanned {
            guard occurrences.count < limit else { break }
            guard let departureDate = calendar.nextDate(
                after: searchFrom,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else { break }

            searchFrom = departureDate
            let leaveDate = departureDate.addingTimeInterval(TimeInterval(-leadMinutes * 60))

            // The leave moment, not the departure, is what we alert on.
            guard leaveDate > referenceDate else { continue }
            guard !isSkipped(route: route, departureDate: departureDate, direction: direction) else { continue }

            occurrences.append(Occurrence(departureDate: departureDate, leaveDate: leaveDate))
        }

        return occurrences
    }

    private static func isSkipped(
        route: SavedCommuteRoute,
        departureDate: Date,
        direction: CommuteDirection
    ) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: departureDate)
        if route.skippedDates.contains(where: { calendar.isDate($0, inSameDayAs: day) }) { return true }
        return route.isOccurrenceSkipped(on: day, direction: direction)
    }
}

// MARK: - CommuteNotificationReconciler

/// Rebuilds every repeat-schedule notification from current settings.
///
/// Lives outside the view models so the background refresh task can run it too —
/// otherwise a skip only took effect if the user happened to open the app that day.
enum CommuteNotificationReconciler {
    /// iOS keeps only the 64 soonest-firing pending notifications and silently drops
    /// the rest, so repeat schedules claim at most this many and leave the remainder
    /// for one-off reminders.
    static let pendingNotificationBudget = 40

    @MainActor
    private struct Context {
        let route: SavedCommuteRoute
        let config: RouteConfiguration
    }

    /// Reconciles run one at a time. Several call sites can trigger one at once
    /// (saving a schedule while the daily reconcile fires, for instance), and since
    /// each run cancels everything before rescheduling, overlapping runs could delete
    /// notifications another run had just added.
    private static let queue = SerialQueue()

    static func reconcile(
        referenceDate: Date = Date(),
        notificationService: NotificationServiceProtocol = NotificationService.shared
    ) async {
        await queue.run {
            await performReconcile(referenceDate: referenceDate, notificationService: notificationService)
        }
    }

    @discardableResult
    private static func performReconcile(
        referenceDate: Date,
        notificationService: NotificationServiceProtocol
    ) async -> Int {
        let context = await MainActor.run { () -> Context in
            let settings = SettingsManager.shared
            var route = settings.savedCommuteRoute
            let before = route
            route.pruneOldSkippedDates()
            if route != before { settings.updateSavedCommuteRoute(route) }
            return Context(route: route, config: settings.trainCommuteConfig)
        }

        // Must finish before rescheduling: identifiers are deterministic, so a late
        // removal would delete what we add below.
        await notificationService.cancelAllCommuteNotifications()

        let active = activeSchedules(in: context.route)
        guard !active.isEmpty else { return 0 }

        // Two alerts per occurrence. Plan more than one week ahead when the budget
        // allows, so alarms survive a stretch where the app is never opened.
        let perOccurrenceCost = 2
        let occurrencesPerSchedule = max(
            1,
            min(2, pendingNotificationBudget / max(1, active.count * perOccurrenceCost))
        )

        var scheduled = 0
        for entry in active {
            let occurrences = CommuteOccurrencePlanner.upcomingOccurrences(
                route: context.route,
                day: entry.day,
                schedule: entry.schedule,
                direction: entry.direction,
                config: context.config,
                referenceDate: referenceDate,
                limit: occurrencesPerSchedule
            )

            for (index, occurrence) in occurrences.enumerated() {
                do {
                    try await notificationService.scheduleCommuteNotification(
                        route: context.route,
                        day: entry.day,
                        schedule: entry.schedule,
                        direction: entry.direction,
                        config: context.config,
                        occurrence: occurrence,
                        occurrenceIndex: index
                    )
                    scheduled += perOccurrenceCost
                } catch {
                    // Permission revoked or budget exhausted; later entries will fail too.
                    continue
                }
            }
        }

        return scheduled
    }

    private struct ScheduleEntry {
        let day: Weekday
        let direction: CommuteDirection
        let schedule: DaySchedule
    }

    private static func activeSchedules(in route: SavedCommuteRoute) -> [ScheduleEntry] {
        var entries: [ScheduleEntry] = []
        for (day, schedule) in route.toWorkSchedules where route.isDayActive(day, direction: .toWork) {
            entries.append(ScheduleEntry(day: day, direction: .toWork, schedule: schedule))
        }
        for (day, schedule) in route.toHomeSchedules where route.isDayActive(day, direction: .toHome) {
            entries.append(ScheduleEntry(day: day, direction: .toHome, schedule: schedule))
        }
        return entries.sorted { $0.day.rawValue < $1.day.rawValue }
    }
}
