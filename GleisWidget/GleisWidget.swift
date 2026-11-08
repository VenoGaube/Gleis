import AppIntents
import SwiftUI
import WidgetKit

// MARK: - SelectTransportIntent

struct SelectTransportIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Gleis Widget"
    static var description: IntentDescription = "Shows the same departures as the Transport view"
}

// MARK: - GleisProvider

struct GleisProvider: AppIntentTimelineProvider {
    /// How far ahead we materialise one-minute countdown ticks. Beyond this the
    /// reload policy refreshes the timeline, so pre-rendering further is wasted work.
    private static let minuteTickHorizon: TimeInterval = 60 * 60
    /// Hard ceiling on timeline length. The horizon above keeps us well under this;
    /// it exists so a pathological snapshot can never produce an unbounded timeline.
    private static let maximumEntryCount = 150
    /// Seconds before the leave time at which the countdown changes colour.
    private static let urgencyThresholds: [TimeInterval] = [300, 120]
    /// Reload interval when only the app can bring new data, since the extension never fetches.
    private static let awaitingAppReloadInterval: TimeInterval = 15 * 60

    func placeholder(in _: Context) -> GleisEntry {
        GleisEntry(date: Date(), data: WidgetData.placeholder, configuration: SelectTransportIntent())
    }

    func snapshot(for configuration: SelectTransportIntent, in _: Context) async -> GleisEntry {
        let now = Date()
        return GleisEntry(date: now, data: loadData(), configuration: configuration)
    }

    func timeline(for configuration: SelectTransportIntent, in _: Context) async -> Timeline<GleisEntry> {
        let data = loadData()
        let now = Date()

        guard let data else {
            let isUnreadable = AppGroupStorage.isPrimaryWidgetSnapshotUnreadable()
            WidgetSyncDiagnostics.staleDisplay(
                reason: isUnreadable ? "snapshot_unreadable" : "no_snapshot_available",
                generatedAt: now,
                coverageEnd: now
            )
            // An unreadable snapshot means the app has one but this build can't parse
            // it; telling the user to set up a route they already have would be wrong.
            let snapshot: WidgetRenderSnapshot? = isUnreadable
                ? WidgetRenderSnapshot(
                    routeText: "",
                    compactRouteText: "",
                    state: .stale,
                    stateMessage: "Open Gleis to refresh departures.",
                    recoveryAction: .openLiveRoute,
                    connection: nil,
                    leaveTime: nil
                )
                : nil
            let entry = GleisEntry(date: now, snapshot: snapshot, configuration: configuration)
            return Timeline(entries: [entry], policy: timelineReloadPolicy(now: now, data: nil, entryCount: 1))
        }

        let isExhausted = data.isCoverageExhausted(at: now)
        if isExhausted || data.state == .stale {
            if isExhausted, data.state != .stale {
                WidgetSyncDiagnostics.staleDisplay(
                    reason: "coverage_exhausted",
                    generatedAt: data.generatedAt,
                    coverageEnd: data.coverageEnd
                )
            }
            let entry = GleisEntry(
                date: now,
                snapshot: data.renderSnapshot(at: now, overridingState: .stale, message: "Refreshing departures..."),
                configuration: configuration
            )
            return Timeline(entries: [entry], policy: timelineReloadPolicy(now: now, data: data, entryCount: 1))
        }

        let instants = renderInstants(for: data, now: now)
        let entries = instants.map { instant -> GleisEntry in
            // Past the covered horizon we can no longer vouch for the data, so the
            // boundary entry flips the widget into its refreshing state.
            let isPastCoverage = instant > data.coverageEnd
            return GleisEntry(
                date: instant,
                snapshot: data.renderSnapshot(
                    at: instant,
                    overridingState: isPastCoverage ? .stale : nil,
                    message: isPastCoverage ? "Refreshing departures..." : nil
                ),
                configuration: configuration,
                laterDepartureTimes: isPastCoverage ? [] : data.laterDepartureTimes(at: instant)
            )
        }

        return Timeline(
            entries: entries,
            policy: timelineReloadPolicy(now: now, data: data, entryCount: entries.count)
        )
    }

    private func loadData() -> WidgetData? {
        AppGroupStorage.loadPrimaryWidgetData()
    }

    // MARK: - Entry Scheduling

    /// The instants at which the rendered widget actually changes.
    ///
    /// Sub-minute countdowns are deliberately absent: the views use
    /// `Text(timerInterval:countsDown:)` inside the final minute, which updates itself without
    /// needing an entry per second.
    private func renderInstants(for data: WidgetData, now: Date) -> [Date] {
        var instants: Set<Date> = [now]
        let horizonEnd = now.addingTimeInterval(Self.minuteTickHorizon)

        // `connection(at:)` surfaces the first connection still catchable at a given
        // instant, so the displayed journey rolls over exactly at its leave time.
        // Walk that chain forward until it leaves the horizon. Each step strictly
        // advances the cursor past a leave time, and there are finitely many, so the
        // connection count bounds the walk.
        var cursor = now
        var remainingSteps = data.connectionCount
        while remainingSteps > 0, cursor <= horizonEnd, let current = data.connection(at: cursor) {
            insertCountdownInstants(for: current.leaveTime, from: cursor, through: horizonEnd, into: &instants)
            guard current.leaveTime <= horizonEnd else { break }
            cursor = current.leaveTime
            remainingSteps -= 1
        }

        let coverageBoundary = data.coverageEnd.addingTimeInterval(1)
        if coverageBoundary > now, coverageBoundary <= horizonEnd { instants.insert(coverageBoundary) }

        let sorted = instants.filter { $0 >= now }.sorted()
        return Array(sorted.prefix(Self.maximumEntryCount))
    }

    /// Minute boundaries of the countdown to `leaveTime`, plus the colour-change and
    /// arrival instants, limited to the `start...end` window.
    private func insertCountdownInstants(
        for leaveTime: Date,
        from start: Date,
        through end: Date,
        into instants: inout Set<Date>
    ) {
        guard leaveTime > start else { return }
        var candidates = Self.urgencyThresholds.map { leaveTime.addingTimeInterval(-$0) }
        candidates.append(leaveTime)

        // Start at the latest minute boundary inside the window rather than walking
        // back from a leave time that may be many hours out.
        var tick = leaveTime.addingTimeInterval(-60)
        if tick > end {
            let minutesBeyond = (tick.timeIntervalSince(end) / 60).rounded(.up)
            tick = tick.addingTimeInterval(-minutesBeyond * 60)
        }
        while tick > start {
            candidates.append(tick)
            tick = tick.addingTimeInterval(-60)
        }

        for candidate in candidates where candidate > start && candidate <= end {
            instants.insert(candidate)
        }
    }

    // MARK: - Reload Policy

    private func timelineReloadPolicy(
        now: Date,
        data: WidgetData?,
        entryCount: Int
    ) -> TimelineReloadPolicy {
        guard let data else {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_no_data_10m")
            return .after(now.addingTimeInterval(10 * 60))
        }
        if data.state == .stale || data.isCoverageExhausted(at: now) {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_stale_or_exhausted_15m")
            return .after(now.addingTimeInterval(Self.awaitingAppReloadInterval))
        }

        let futureCount = data.futureConnections(from: now).count
        let coverageRemaining = data.coverageEnd.timeIntervalSince(now)
        if futureCount == 0 {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_no_future_15m")
            return .after(now.addingTimeInterval(Self.awaitingAppReloadInterval))
        }
        if futureCount <= 2 || coverageRemaining <= 30 * 60 {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_low_coverage_5m")
            return .after(now.addingTimeInterval(5 * 60))
        }
        // We materialised ticks only up to the horizon, so reload as they run out.
        if entryCount > 1 {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_boundary_entries_at_end")
            return .atEnd
        }
        WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_normal_10m")
        return .after(now.addingTimeInterval(10 * 60))
    }
}

// MARK: - GleisEntry

struct GleisEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetRenderSnapshot?
    let configuration: SelectTransportIntent
    /// Departure times of the next catchable trains after the one the snapshot shows.
    var laterDepartureTimes: [Date] = []

    var relevance: TimelineEntryRelevance? {
        guard let leaveTime = snapshot?.leaveTime else { return nil }
        let remaining = leaveTime.timeIntervalSince(date)
        return TimelineEntryRelevance(score: remaining < 300 ? 1.0 : 0.5)
    }
}

extension GleisEntry {
    /// Convenience for call sites that still hold a full snapshot (placeholders, previews).
    init(date: Date, data: WidgetData?, configuration: SelectTransportIntent) {
        self.init(
            date: date,
            snapshot: data?.renderSnapshot(at: date),
            configuration: configuration,
            laterDepartureTimes: data?.laterDepartureTimes(at: date) ?? []
        )
    }
}

private extension WidgetData {
    /// How many follow-on departures the medium widget lists after the shown train.
    static let laterDepartureLimit = 2

    func laterDepartureTimes(at date: Date) -> [Date] {
        futureConnections(from: date)
            .dropFirst()
            .filter { !$0.connection.isCancelled }
            .prefix(Self.laterDepartureLimit)
            .map(\.connection.departureTime)
    }
}

// MARK: - GleisWidgetEntryView

struct GleisWidgetEntryView: View {
    var entry: GleisEntry
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        switch family {
        case .systemSmall: SmallWidgetView(entry: entry).widgetBackground(entry: entry, colorScheme: colorScheme)
        case .accessoryCircular:
            CircularWidgetView(entry: entry).containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular:
            RectangularWidgetView(entry: entry).containerBackground(for: .widget) { AccessoryWidgetBackground() }
        default: MediumWidgetView(entry: entry).widgetBackground(entry: entry, colorScheme: colorScheme)
        }
    }
}

extension View {
    func widgetBackground(entry: GleisEntry, colorScheme: ColorScheme) -> some View {
        let color: Color = {
            guard let data = entry.snapshot else {
                return colorScheme == .dark ? Color(.systemBackground) : .white
            }
            if data.state == .fallback { return .orange }
            if data.state == .stale { return .gray }
            guard let leaveTime = data.leaveTime else {
                return colorScheme == .dark ? Color(.systemBackground) : .white
            }
            return urgencyColor(leaveTime.timeIntervalSince(entry.date))
        }()

        return containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    color.opacity(0.45), color.opacity(colorScheme == .dark ? 0.12 : 0.1),
                    .clear,
                ], startPoint: .trailing, endPoint: .leading
            )
        }
    }
}

private typealias ScheduledConnection = (connection: WidgetConnection, leaveTime: Date)

// MARK: - SmallWidgetView

/// Leave countdown, departure time, platform and delay, dropping detail as the text size grows.
struct SmallWidgetView: View {
    let entry: GleisEntry

    var body: some View {
        if let data = entry.snapshot, let current = data.scheduled {
            // The system content margins already inset the widget, so the tiers add no outer padding.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 4) {
                    RouteLine(routeText: data.routeText, compactRouteText: data.compactRouteText, alignment: .center)
                    badgeRow(current.connection)
                    Spacer(minLength: 0)
                    CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date)
                    Spacer(minLength: 0)
                    DepartureInfo(connection: current.connection)
                }
                VStack(spacing: 4) {
                    RouteLine(routeText: data.routeText, compactRouteText: data.compactRouteText, alignment: .center)
                    badgeRow(current.connection)
                    Spacer(minLength: 0)
                    CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date)
                    Spacer(minLength: 0)
                    CompactDepartureLine(connection: current.connection)
                }
                VStack(spacing: 4) {
                    badgeRow(current.connection)
                    CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date)
                    CompactDepartureLine(connection: current.connection)
                }
                VStack(spacing: 4) {
                    CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date)
                    CompactDepartureLine(connection: current.connection)
                }
                CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date)
                CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date, showsLabel: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(entryURL(entry, fallbackConnectionId: current.connection.id))
        } else {
            EmptyWidgetView(size: .small, snapshot: entry.snapshot)
        }
    }

    private func badgeRow(_ connection: WidgetConnection) -> some View {
        HStack(spacing: 6) {
            LineBadge(line: connection.lineNumber, lineColors: connection.lineColors, size: .small)
            if connection.isCancelled {
                Image(systemName: "xmark.octagon.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Service cancelled")
            } else if connection.hasServiceAlert {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Service alert")
            }
        }
    }
}

// MARK: - MediumWidgetView

/// Leave countdown beside the train, departure, platform and the next departures after it.
struct MediumWidgetView: View {
    let entry: GleisEntry

    var body: some View {
        if let data = entry.snapshot, let current = data.scheduled {
            ViewThatFits(in: .vertical) {
                HStack(alignment: .center, spacing: 12) {
                    leaveColumn(current, showsLeaveAt: true)
                    detailColumn(data, current.connection, showsRoute: true, showsLater: true)
                }
                HStack(alignment: .center, spacing: 12) {
                    leaveColumn(current, showsLeaveAt: true)
                    detailColumn(data, current.connection, showsRoute: false, showsLater: true)
                }
                HStack(alignment: .center, spacing: 12) {
                    leaveColumn(current, showsLeaveAt: true)
                    detailColumn(data, current.connection, showsRoute: false, showsLater: false)
                }
                HStack(alignment: .center, spacing: 12) {
                    leaveColumn(current, showsLeaveAt: false)
                    CompactDepartureLine(connection: current.connection, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date)
                    .frame(maxWidth: .infinity)
                CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date, showsLabel: false)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(entryURL(entry, fallbackConnectionId: current.connection.id))
        } else {
            EmptyWidgetView(size: .medium, snapshot: entry.snapshot)
        }
    }

    private func leaveColumn(_ current: ScheduledConnection, showsLeaveAt: Bool) -> some View {
        VStack(spacing: 4) {
            CountdownDisplay(leaveTime: current.leaveTime, referenceDate: entry.date)
            if showsLeaveAt, current.leaveTime > entry.date {
                Text("Leave at \(current.leaveTime, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        // Keeps the countdown at its natural width so the detail column is the one that gives way.
        .layoutPriority(1)
    }

    private func detailColumn(
        _ data: WidgetRenderSnapshot,
        _ connection: WidgetConnection,
        showsRoute: Bool,
        showsLater: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsRoute {
                RouteLine(routeText: data.routeText, compactRouteText: data.compactRouteText)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    LineBadge(line: connection.lineNumber, lineColors: connection.lineColors, size: .medium)
                    ServiceStatusLine(connection: connection)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LineBadge(line: connection.lineNumber, lineColors: connection.lineColors, size: .medium)
                    ServiceStatusLine(connection: connection)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    departureTimeText(connection)
                    platformText("Platform \(connection.displayPlatform)")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    departureTimeText(connection)
                    platformText("Pl \(connection.displayPlatform)")
                }
                VStack(alignment: .leading, spacing: 0) {
                    departureTimeText(connection)
                    platformText("Pl \(connection.displayPlatform)")
                }
            }

            if showsLater, !entry.laterDepartureTimes.isEmpty {
                LaterDeparturesLine(departureTimes: entry.laterDepartureTimes)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func departureTimeText(_ connection: WidgetConnection) -> some View {
        Text(timeFormatter.string(from: connection.departureTime))
            .font(.title3.weight(.bold).monospacedDigit())
            .scalableText(minimumScale: 0.8)
    }

    private func platformText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .scalableText(minimumScale: 0.8)
    }
}

// MARK: - CircularWidgetView

/// Pure countdown - just what you need at a glance
struct CircularWidgetView: View {
    let entry: GleisEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let data = entry.snapshot, let current = data.scheduled {
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            let progress = min(1, max(0, remaining / 1800))

            ZStack {
                // Background ring
                Circle().stroke(lineWidth: 4).opacity(0.2)

                // Progress ring
                if remaining > 0 {
                    Circle().trim(from: 0, to: progress).stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90)).widgetAccentable()
                }

                if remaining <= 0 {
                    Text("GO")
                        .font(.system(.headline, design: .rounded, weight: .black))
                        .scalableText(minimumScale: 0.8)
                } else if remaining <= 60 {
                    Text(timerInterval: entry.date...max(entry.date, current.leaveTime), countsDown: true, showsHours: false)
                        .font(.system(.subheadline, design: .rounded, weight: .bold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .scalableText(minimumScale: 0.8)
                } else {
                    ViewThatFits(in: .vertical) {
                        VStack(spacing: 0) {
                            circularMinutes(remaining)
                            Text("min")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .scalableText(minimumScale: 0.8)
                        }
                        circularMinutes(remaining)
                    }
                }
            }
            .padding(4)
            // The face never grows, so text stops growing at the size where three digits still fit inside the ring.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLeaveSummary(for: current, at: entry.date))
            .widgetURL(entryURL(entry, fallbackConnectionId: current.connection.id))
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "tram.fill").font(.title3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gleis, \(entry.snapshot?.emptyHintText ?? WidgetRenderSnapshot.missingHintText)")
            .widgetURL(entryURL(entry))
        }
    }

    private func circularMinutes(_ remaining: TimeInterval) -> some View {
        Text("\(minutesRemaining(remaining))")
            .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
            .multilineTextAlignment(.center)
            .scalableText(minimumScale: 0.8)
    }
}

// MARK: - RectangularWidgetView

/// Route, train and countdown on up to three lines, dropping the route and then the train as text grows.
struct RectangularWidgetView: View {
    let entry: GleisEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let data = entry.snapshot, let current = data.scheduled {
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    RouteLine(routeText: data.routeText, compactRouteText: data.compactRouteText)
                    trainLine(current.connection)
                    countdownLine(current)
                }
                VStack(alignment: .leading, spacing: 2) {
                    trainLine(current.connection)
                    countdownLine(current)
                }
                countdownLine(current)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLeaveSummary(for: current, at: entry.date))
            .widgetURL(entryURL(entry, fallbackConnectionId: current.connection.id))
        } else {
            let hint = entry.snapshot?.emptyHintText ?? WidgetRenderSnapshot.missingHintText
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    emptyHeader
                    emptyHint(hint)
                }
                emptyHint(hint)
                emptyHeader
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gleis, \(hint)")
            .widgetURL(entryURL(entry))
        }
    }

    private var emptyHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "tram.fill").widgetAccentable()
            Text("Gleis").fontWeight(.semibold).scalableText(minimumScale: 0.8)
        }
        .font(.headline)
    }

    private func emptyHint(_ hint: String) -> some View {
        Text(hint).font(.subheadline).foregroundStyle(.secondary).minimumScaleFactor(0.8)
    }

    private func trainLine(_ connection: WidgetConnection) -> some View {
        let lineText = Text(connection.lineNumber)
            .font(.headline.weight(.bold))
            .widgetAccentable()
            .scalableText(minimumScale: 0.8)
        let departureText = Text(timeFormatter.string(from: connection.departureTime))
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .scalableText(minimumScale: 0.8)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                lineText
                departureText
                Text("Pl \(connection.displayPlatform)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .scalableText(minimumScale: 0.8)
            }
            HStack(spacing: 6) {
                lineText
                departureText
            }
            VStack(alignment: .leading, spacing: 0) {
                lineText
                departureText
            }
        }
    }

    private func countdownLine(_ current: ScheduledConnection) -> some View {
        let remaining = current.leaveTime.timeIntervalSince(entry.date)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                countdownValue(current, remaining: remaining)
                if remaining > 0, remaining <= 60 {
                    Text("to go").font(.caption).foregroundStyle(.secondary).scalableText(minimumScale: 0.8)
                }
                statusLabel(current.connection)
            }
            HStack(spacing: 4) {
                countdownValue(current, remaining: remaining)
                statusLabel(current.connection)
            }
            countdownValue(current, remaining: remaining)
        }
    }

    @ViewBuilder
    private func countdownValue(_ current: ScheduledConnection, remaining: TimeInterval) -> some View {
        let font = Font.subheadline.weight(.bold).monospacedDigit()
        if remaining <= 0 {
            Text("GO!").font(font).widgetAccentable().scalableText(minimumScale: 0.8)
        } else if remaining <= 60 {
            Text(timerInterval: entry.date...max(entry.date, current.leaveTime), countsDown: true, showsHours: false)
                .font(font)
                .widgetAccentable()
                .scalableText(minimumScale: 0.8)
        } else {
            Text("\(minutesRemaining(remaining))m")
                .font(font)
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                .widgetAccentable()
                .scalableText(minimumScale: 0.8)
        }
    }

    @ViewBuilder
    private func statusLabel(_ connection: WidgetConnection) -> some View {
        if connection.isCancelled {
            Text("Cancelled").font(.caption2.weight(.bold)).foregroundStyle(.red).scalableText(minimumScale: 0.8)
        } else {
            if connection.isDelayed {
                Text("+\(connection.delay) min")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .scalableText(minimumScale: 0.8)
            }
            if connection.hasServiceAlert {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - RouteLine

/// The searched route on one line, falling back to first words, then to wrapping onto two lines.
private struct RouteLine: View {
    let routeText: String
    let compactRouteText: String
    var alignment: TextAlignment = .leading

    var body: some View {
        ViewThatFits(in: .horizontal) {
            singleLine(routeText)
            singleLine(compactRouteText)
            styled(Text(compactRouteText))
                .multilineTextAlignment(alignment)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    private func singleLine(_ text: String) -> some View {
        styled(Text(text)).lineLimit(1).allowsTightening(true)
    }

    private func styled(_ text: Text) -> some View {
        text.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: - ServiceStatusLine

/// Cancelled, delay and service alert markers, stacking when they do not fit side by side.
private struct ServiceStatusLine: View {
    let connection: WidgetConnection

    var body: some View {
        if connection.isCancelled {
            marker("Cancelled", systemImage: "xmark.octagon.fill", color: .red, weight: .bold)
        } else if connection.isDelayed || connection.hasServiceAlert {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { markers }
                VStack(alignment: .leading, spacing: 2) { markers }
            }
        }
    }

    @ViewBuilder
    private var markers: some View {
        if connection.isDelayed {
            marker("+\(connection.delay) min", systemImage: "clock.badge.exclamationmark", color: .orange)
        }
        if connection.hasServiceAlert {
            marker("Service alert", systemImage: "exclamationmark.triangle.fill", color: .red)
        }
    }

    private func marker(
        _ text: String,
        systemImage: String,
        color: Color,
        weight: Font.Weight = .semibold
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption.weight(weight)).scalableText(minimumScale: 0.8)
        }
        .foregroundStyle(color)
    }
}

// MARK: - LaterDeparturesLine

/// "Then 23:54 · 00:24", dropping to the next departure alone when both do not fit.
private struct LaterDeparturesLine: View {
    let departureTimes: [Date]

    var body: some View {
        let formatted = departureTimes.map { timeFormatter.string(from: $0) }
        ViewThatFits(in: .horizontal) {
            styled("Then \(formatted.joined(separator: " · "))").lineLimit(1)
            styled("Then \(formatted.first ?? "")").lineLimit(2).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Later trains at \(ListFormatter.localizedString(byJoining: formatted))")
    }

    private func styled(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
    }
}

// MARK: - CompactDepartureLine

/// Departure time and platform on one line, stacking them when one line does not fit.
private struct CompactDepartureLine: View {
    let connection: WidgetConnection
    var alignment: HorizontalAlignment = .center

    var body: some View {
        let time = timeFormatter.string(from: connection.departureTime)
        let platform = "Pl \(connection.displayPlatform)"
        VStack(alignment: alignment, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                Text("\(time) · \(platform)").lineLimit(1)
                VStack(alignment: alignment, spacing: 0) {
                    Text(time).scalableText(minimumScale: 0.8)
                    Text(platform).scalableText(minimumScale: 0.8)
                }
            }
            .font(.headline.weight(.bold).monospacedDigit())

            if connection.isCancelled {
                Text("Cancelled").font(.caption2.weight(.bold)).foregroundStyle(.red).scalableText(minimumScale: 0.8)
            } else if connection.isDelayed {
                Text("+\(connection.delay) min")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .scalableText(minimumScale: 0.8)
            }
        }
    }
}

// MARK: - LineBadge

struct LineBadge: View {
    let line: String
    let lineColors: TrainLineColors?
    let size: BadgeSize

    enum BadgeSize {
        case small, medium

        var font: Font {
            switch self {
            case .small: .caption.weight(.bold)
            case .medium: .subheadline.weight(.bold)
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .small: 4
            case .medium: 5
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: 8
            case .medium: 10
            }
        }
    }

    init(line: String, lineColors: TrainLineColors? = nil, size: BadgeSize) {
        self.line = line
        self.lineColors = lineColors
        self.size = size
    }

    var body: some View {
        let style = Color.lineBadgeStyle(for: line, apiColors: lineColors)
        return Text(line)
            .font(size.font)
            .foregroundStyle(style.foreground)
            .scalableText(minimumScale: 0.8)
            .padding(.vertical, size.verticalPadding)
            .padding(.horizontal, size.horizontalPadding)
            .background(style.background, in: Capsule())
    }
}

// MARK: - CountdownDisplay

struct CountdownDisplay: View {
    let leaveTime: Date
    let referenceDate: Date
    var showsLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let mainFont: Font = .system(.title, design: .rounded, weight: .bold)
    private static let labelFont: Font = .caption2.weight(.medium)

    var body: some View {
        let remaining = leaveTime.timeIntervalSince(referenceDate)
        VStack(spacing: 2) {
            if remaining <= 0 {
                Text("GO!").font(Self.mainFont).foregroundStyle(.secondary).scalableText(minimumScale: 0.8)
            } else if remaining <= 60 {
                // A closed range stops at 0:00, where the style: .timer form would start counting up.
                Text(timerInterval: referenceDate...max(referenceDate, leaveTime), countsDown: true, showsHours: false)
                    .font(Self.mainFont.monospacedDigit())
                    .foregroundStyle(urgencyColor(remaining))
                    .multilineTextAlignment(.center)
                    .scalableText(minimumScale: 0.8)
                label("leave now")
            } else {
                Text("\(minutesRemaining(remaining))m")
                    .font(Self.mainFont.monospacedDigit())
                    .foregroundStyle(urgencyColor(remaining))
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    .multilineTextAlignment(.center)
                    .scalableText(minimumScale: 0.8)
                label("to leave")
            }
        }
    }

    @ViewBuilder
    private func label(_ text: String) -> some View {
        if showsLabel {
            Text(text)
                .font(Self.labelFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - DepartureInfo

struct DepartureInfo: View {
    let connection: WidgetConnection

    private let labelFont: Font = .caption2.weight(.semibold)
    private let valueFont: Font = .headline.weight(.bold).monospacedDigit()

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top) {
                departureColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                platformColumn
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if connection.isDelayed {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2.weight(.semibold))
                    Text("Delay +\(connection.delay) m")
                        .font(.caption2.weight(.semibold))
                        .scalableText(minimumScale: 0.8)
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var departureColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Departure")
                .font(labelFont)
                .foregroundStyle(.secondary)
                .scalableText(minimumScale: 0.8)

            Text(timeFormatter.string(from: connection.departureTime))
                .font(valueFont)
                .foregroundStyle(connection.isDelayed ? Color.orange : Color.primary)
                .scalableText(minimumScale: 0.8)
        }
    }

    private var platformColumn: some View {
        VStack(alignment: .center, spacing: 2) {
            Text("Platform")
                .font(labelFont)
                .foregroundStyle(.secondary)
                .scalableText(minimumScale: 0.8)
            Text(connection.displayPlatform).font(valueFont).scalableText(minimumScale: 0.8)
        }
    }
}

private extension WidgetConnection {
    var trimmedPlatform: String? {
        let trimmed = platform?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var displayPlatform: String { trimmedPlatform ?? "–" }
}

// MARK: - EmptyWidgetView

struct EmptyWidgetView: View {
    let size: EmptySize
    let snapshot: WidgetRenderSnapshot?

    @ScaledMetric(relativeTo: .title3) private var smallIconBackdrop: CGFloat = 48
    @ScaledMetric(relativeTo: .title2) private var mediumIconBackdrop: CGFloat = 56

    enum EmptySize { case small, medium }

    init(size: EmptySize, snapshot: WidgetRenderSnapshot?) {
        self.size = size
        self.snapshot = snapshot
    }

    var body: some View {
        let accentColor: Color = switch snapshot?.state {
        case .fallback: .orange
        case .stale: .secondary
        default: .trainBlue
        }
        let hasSnapshot = snapshot != nil
        let title = switch snapshot?.state {
        case .fallback: "Offline data"
        case .stale: "No departures"
        default: hasSnapshot ? "No departures" : "Set up route"
        }
        let subtitle = snapshot?.emptyHintText ?? WidgetRenderSnapshot.missingHintText

        switch size {
        case .small:
            ViewThatFits(in: .vertical) {
                VStack(spacing: 10) {
                    icon(accentColor, backdrop: smallIconBackdrop, font: .title3)
                    smallTitle(title)
                }
                smallTitle(title)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(recoveryURL(for: snapshot))

        case .medium:
            ViewThatFits(in: .vertical) {
                HStack(spacing: 16) {
                    icon(accentColor, backdrop: mediumIconBackdrop, font: .title2)
                    mediumText(title: title, subtitle: subtitle)
                    Spacer(minLength: 0)
                }
                mediumText(title: title, subtitle: subtitle)
                Text(title).font(.headline).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(recoveryURL(for: snapshot))
        }
    }

    private func icon(_ accentColor: Color, backdrop: CGFloat, font: Font) -> some View {
        ZStack {
            Circle().fill(accentColor.opacity(0.1)).frame(width: backdrop, height: backdrop)
            Image(systemName: "tram.fill").font(font).foregroundStyle(accentColor)
        }
        .accessibilityHidden(true)
    }

    private func smallTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
    }

    private func mediumText(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: - ScalableText

/// ViewModifier for one-line text that shrinks to fit available space
struct ScalableText: ViewModifier {
    let minimumScaleFactor: CGFloat

    init(minimumScaleFactor: CGFloat = 0.8) { self.minimumScaleFactor = minimumScaleFactor }

    func body(content: Content) -> some View { content.minimumScaleFactor(minimumScaleFactor).lineLimit(1) }
}

extension View {
    /// Makes text scalable, shrinking to fit available space if needed
    func scalableText(minimumScale: CGFloat = 0.8) -> some View {
        modifier(ScalableText(minimumScaleFactor: minimumScale))
    }
}

// MARK: - Helpers

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    return f
}()

private func entryURL(_ entry: GleisEntry, fallbackConnectionId: String? = nil) -> URL? {
    if let data = entry.snapshot, data.state != .fresh, let url = recoveryURL(for: data) { return url }
    if let fallbackConnectionId { return connectionDeepLink(id: fallbackConnectionId) }
    return URL(string: "gleis://commute")
}

private func recoveryURL(for snapshot: WidgetRenderSnapshot?) -> URL? {
    guard let action = snapshot?.recoveryAction else {
        if snapshot == nil { return URL(string: "gleis://setup") }
        return nil
    }

    switch action {
    case .openLiveRoute:
        return URL(string: "gleis://commute")
    case .openRepeatJourney:
        return URL(string: "gleis://repeat")
    case .openSetup:
        return URL(string: "gleis://setup")
    }
}

private func connectionDeepLink(id: String) -> URL? {
    let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
    return URL(string: "gleis://connection?id=\(encodedId)")
}

private func minutesRemaining(_ remaining: TimeInterval) -> Int {
    max(1, Int(ceil(remaining / 60)))
}

/// One VoiceOver sentence for the lock-screen widgets, which hide their individual glyphs.
private func spokenLeaveSummary(for current: ScheduledConnection, at date: Date) -> String {
    let connection = current.connection
    let remaining = current.leaveTime.timeIntervalSince(date)
    var parts: [String] = []
    if remaining <= 0 {
        parts.append("Leave now")
    } else if remaining <= 60 {
        parts.append("Leave in under a minute")
    } else {
        let minutes = minutesRemaining(remaining)
        parts.append("Leave in \(minutes) \(minutes == 1 ? "minute" : "minutes")")
    }
    parts.append("\(connection.lineNumber) to \(connection.destination) at \(timeFormatter.string(from: connection.departureTime))")
    if let platform = connection.trimmedPlatform { parts.append("platform \(platform)") }
    if connection.isCancelled {
        parts.append("cancelled")
    } else {
        if connection.isDelayed { parts.append("\(connection.delay) \(connection.delay == 1 ? "minute" : "minutes") late") }
        if connection.hasServiceAlert { parts.append("service alert") }
    }
    return parts.joined(separator: ", ")
}

private func urgencyColor(_ remaining: TimeInterval) -> Color {
    if remaining <= 0 { return .secondary }
    if remaining < 120 { return .red }
    if remaining < 300 { return .orange }
    return .green
}

// MARK: - Color Extension

private struct LineBadgeStyle {
    let background: Color
    let foreground: Color
}

extension Color {
    static let trainBlue = Color(red: 0.0, green: 0.48, blue: 0.85)

    static func lineColor(for line: String) -> Color {
        let uppercased = line.uppercased()

        // Vienna U-Bahn colors
        if uppercased == "U1" { return Color(red: 0.89, green: 0.15, blue: 0.21) }
        if uppercased == "U2" { return Color(red: 0.58, green: 0.22, blue: 0.58) }
        if uppercased == "U3" { return Color(red: 0.95, green: 0.55, blue: 0.15) }
        if uppercased == "U4" { return Color(red: 0.2, green: 0.65, blue: 0.35) }
        if uppercased == "U6" { return Color(red: 0.6, green: 0.45, blue: 0.25) }

        // S-Bahn green
        if uppercased.hasPrefix("S") { return Color(red: 0.2, green: 0.55, blue: 0.35) }

        // Regional trains
        if uppercased.hasPrefix("R") || uppercased.hasPrefix("REX") { return Color(red: 0.7, green: 0.1, blue: 0.1) }

        // Default railway blue
        return trainBlue
    }

    fileprivate static func lineBadgeStyle(for line: String, apiColors: TrainLineColors?) -> LineBadgeStyle {
        let fallbackBackground = lineColor(for: line)
        guard let apiColors else { return LineBadgeStyle(background: fallbackBackground, foreground: .white) }
        let backgroundHex = apiColors.accentHex ?? apiColors.backgroundHex
        let background = color(fromHex: backgroundHex) ?? fallbackBackground
        return LineBadgeStyle(background: background, foreground: .white)
    }

    private static func color(fromHex hex: String?) -> Color? {
        guard let hex, let components = rgbComponents(forHex: hex) else { return nil }
        return Color(
            red: Double(components.red) / 255,
            green: Double(components.green) / 255,
            blue: Double(components.blue) / 255
        )
    }

    private static func rgbComponents(forHex hex: String) -> (red: Int, green: Int, blue: Int)? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        if raw.count == 3 {
            raw = raw.map { "\($0)\($0)" }.joined()
        }
        guard raw.count == 6 || raw.count == 8 else { return nil }
        let rgb = raw.count == 8 ? String(raw.dropFirst(2)) : raw
        guard let value = Int(rgb, radix: 16) else { return nil }
        return (red: (value >> 16) & 0xFF, green: (value >> 8) & 0xFF, blue: value & 0xFF)
    }
}

// MARK: - GleisWidget

struct GleisWidget: Widget {
    let kind = "GleisWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectTransportIntent.self, provider: GleisProvider()) { entry in
            GleisWidgetEntryView(entry: entry)
        }.configurationDisplayName("Gleis").description("Your next train at a glance").supportedFamilies([
            .systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular,
        ])
    }
}

// MARK: - GleisWidgetBundle

@main
struct GleisWidgetBundle: WidgetBundle { var body: some Widget { GleisWidget() } }

// MARK: - Previews

#Preview("Small", as: .systemSmall) { GleisWidget() } timeline: {
    GleisEntry(date: Date(), data: .placeholder, configuration: SelectTransportIntent())
    GleisEntry(date: Date(), data: .delayedPlaceholder, configuration: SelectTransportIntent())
    GleisEntry(date: Date(), data: nil, configuration: SelectTransportIntent())
}

#Preview("Medium", as: .systemMedium) { GleisWidget() } timeline: {
    GleisEntry(date: Date(), data: .placeholder, configuration: SelectTransportIntent())
    GleisEntry(date: Date(), data: .delayedPlaceholder, configuration: SelectTransportIntent())
    GleisEntry(date: Date(), data: nil, configuration: SelectTransportIntent())
}

#Preview("Rectangular", as: .accessoryRectangular) { GleisWidget() } timeline: {
    GleisEntry(date: Date(), data: .placeholder, configuration: SelectTransportIntent())
    GleisEntry(date: Date(), data: nil, configuration: SelectTransportIntent())
}

#Preview("Circular", as: .accessoryCircular) { GleisWidget() } timeline: {
    GleisEntry(date: Date(), data: .placeholder, configuration: SelectTransportIntent())
    GleisEntry(date: Date(), data: nil, configuration: SelectTransportIntent())
}
