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
    func placeholder(in _: Context) -> GleisEntry {
        GleisEntry(date: Date(), data: WidgetData.placeholder, configuration: SelectTransportIntent())
    }

    func snapshot(for configuration: SelectTransportIntent, in _: Context) async -> GleisEntry {
        GleisEntry(date: Date(), data: loadData(), configuration: configuration)
    }

    func timeline(for configuration: SelectTransportIntent, in _: Context) async -> Timeline<GleisEntry> {
        let data = loadData()
        let now = Date()
        var entries: [GleisEntry] = []
        var scheduledTimestamps = Set<Int>()

        if let data {
            let activeData = staleAdjustedData(data, now: now)
            appendTimelineEntry(
                at: now,
                data: activeData,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )

            if activeData.state != .stale {
                appendBoundaryEntries(
                    for: activeData,
                    now: now,
                    configuration: configuration,
                    entries: &entries,
                    scheduledTimestamps: &scheduledTimestamps
                )
            }
        } else {
            WidgetSyncDiagnostics.staleDisplay(
                reason: "no_snapshot_available",
                generatedAt: now,
                coverageEnd: now
            )
            appendTimelineEntry(
                at: now,
                data: nil,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )
        }

        let sortedEntries = entries.sorted { $0.date < $1.date }
        let refreshPolicy = timelineReloadPolicy(now: now, data: data, entryCount: sortedEntries.count)

        return Timeline(entries: sortedEntries, policy: refreshPolicy)
    }

    private func loadData() -> WidgetData? {
        AppGroupStorage.loadPrimaryWidgetData(for: .trainCommute)
    }

    private func staleAdjustedData(_ data: WidgetData, now: Date) -> WidgetData {
        guard data.state != .stale else { return data }
        guard data.isCoverageExhausted(at: now) else { return data }
        WidgetSyncDiagnostics.staleDisplay(
            reason: "coverage_exhausted",
            generatedAt: data.generatedAt,
            coverageEnd: data.coverageEnd
        )
        return staleData(from: data, updatedAt: now, message: "Refreshing departures...")
    }

    private func appendBoundaryEntries(
        for data: WidgetData,
        now: Date,
        configuration: SelectTransportIntent,
        entries: inout [GleisEntry],
        scheduledTimestamps: inout Set<Int>
    ) {
        if let current = data.connection(at: now) {
            appendMinuteCountdownEntries(
                for: current.leaveTime,
                now: now,
                data: data,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )
            appendSecondCountdownEntries(
                from: max(now, current.leaveTime.addingTimeInterval(-60)),
                through: current.leaveTime,
                data: data,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )

            if current.leaveTime > now {
                appendTimelineEntry(
                    at: current.leaveTime,
                    data: data,
                    configuration: configuration,
                    entries: &entries,
                    scheduledTimestamps: &scheduledTimestamps
                )
            }

            let nextTransition = current.leaveTime.addingTimeInterval(1)
            appendTimelineEntry(
                at: nextTransition,
                data: data,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )
            if let next = data.connection(at: nextTransition) {
                appendMinuteCountdownEntries(
                    for: next.leaveTime,
                    now: now,
                    data: data,
                    configuration: configuration,
                    entries: &entries,
                    scheduledTimestamps: &scheduledTimestamps
                )
                appendSecondCountdownEntries(
                    from: max(now, next.leaveTime.addingTimeInterval(-60)),
                    through: next.leaveTime,
                    data: data,
                    configuration: configuration,
                    entries: &entries,
                    scheduledTimestamps: &scheduledTimestamps
                )

                if next.leaveTime > now {
                    appendTimelineEntry(
                        at: next.leaveTime,
                        data: data,
                        configuration: configuration,
                        entries: &entries,
                        scheduledTimestamps: &scheduledTimestamps
                    )
                }
            }
        } else if let firstFuture = data.futureConnections(from: now).first {
            appendMinuteCountdownEntries(
                for: firstFuture.leaveTime,
                now: now,
                data: data,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )
            appendSecondCountdownEntries(
                from: max(now, firstFuture.leaveTime.addingTimeInterval(-60)),
                through: firstFuture.leaveTime,
                data: data,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )
            if firstFuture.leaveTime > now {
                appendTimelineEntry(
                    at: firstFuture.leaveTime,
                    data: data,
                    configuration: configuration,
                    entries: &entries,
                    scheduledTimestamps: &scheduledTimestamps
                )
            }
        }

        let coverageBoundary = data.coverageEnd.addingTimeInterval(1)
        if coverageBoundary > now {
            let staleSnapshot = staleData(from: data, updatedAt: coverageBoundary, message: "Refreshing departures...")
            appendTimelineEntry(
                at: coverageBoundary,
                data: staleSnapshot,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )
        }
    }

    private func appendSecondCountdownEntries(
        from start: Date,
        through end: Date,
        data: WidgetData,
        configuration: SelectTransportIntent,
        entries: inout [GleisEntry],
        scheduledTimestamps: inout Set<Int>
    ) {
        guard end > start else { return }
        var cursor = start
        while cursor <= end {
            appendTimelineEntry(
                at: cursor,
                data: data,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )
            cursor = cursor.addingTimeInterval(1)
        }
    }

    private func appendMinuteCountdownEntries(
        for leaveTime: Date,
        now: Date,
        data: WidgetData,
        configuration: SelectTransportIntent,
        entries: inout [GleisEntry],
        scheduledTimestamps: inout Set<Int>
    ) {
        // Minute updates happen exactly when remaining time crosses a minute boundary.
        // We cap at 12h to avoid excessively large timelines on very distant departures.
        let maximumMinuteEntries = 12 * 60
        var added = 0
        var tick = leaveTime.addingTimeInterval(-60)

        while tick > now, added < maximumMinuteEntries {
            appendTimelineEntry(
                at: tick,
                data: data,
                configuration: configuration,
                entries: &entries,
                scheduledTimestamps: &scheduledTimestamps
            )
            tick = tick.addingTimeInterval(-60)
            added += 1
        }
    }

    private func staleData(from data: WidgetData, updatedAt: Date, message: String) -> WidgetData {
        WidgetData(
            transportType: data.transportType,
            connections: [],
            leaveTimes: [],
            fromStationName: data.fromStationName,
            toStationName: data.toStationName,
            updatedAt: updatedAt,
            generatedAt: updatedAt,
            coverageStart: data.coverageStart,
            coverageEnd: data.coverageEnd,
            routeSignature: data.routeSignature,
            snapshotSignature: data.snapshotSignature,
            state: .stale,
            stateMessage: message,
            recoveryAction: data.recoveryAction
        )
    }

    private func timelineReloadPolicy(
        now: Date,
        data: WidgetData?,
        entryCount: Int
    ) -> TimelineReloadPolicy {
        // When we already provided concrete boundary entries, let the system consume them first.
        if let data, data.state == .fresh, entryCount > 1 {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_boundary_entries_at_end")
            return .atEnd
        }

        guard let data else {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_no_data_10m")
            return .after(now.addingTimeInterval(10 * 60))
        }
        if data.state == .stale || data.isCoverageExhausted(at: now) {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_stale_or_exhausted_1m")
            return .after(now.addingTimeInterval(60))
        }

        let futureCount = data.futureConnections(from: now).count
        let coverageRemaining = data.coverageEnd.timeIntervalSince(now)
        if futureCount == 0 {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_no_future_1m")
            return .after(now.addingTimeInterval(60))
        }
        if futureCount <= 2 || coverageRemaining <= 30 * 60 {
            WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_low_coverage_5m")
            return .after(now.addingTimeInterval(5 * 60))
        }
        WidgetSyncDiagnostics.timelineReloadTriggered(reason: "widget_normal_10m")
        return .after(now.addingTimeInterval(10 * 60))
    }

    private func appendTimelineEntry(
        at date: Date,
        data: WidgetData?,
        configuration: SelectTransportIntent,
        entries: inout [GleisEntry],
        scheduledTimestamps: inout Set<Int>
    ) {
        let key = Int(date.timeIntervalSince1970.rounded())
        guard !scheduledTimestamps.contains(key) else { return }
        scheduledTimestamps.insert(key)
        entries.append(GleisEntry(date: date, data: data, configuration: configuration))
    }

}

// MARK: - GleisEntry

struct GleisEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?
    let configuration: SelectTransportIntent

    var relevance: TimelineEntryRelevance? {
        guard let data, let current = data.connection(at: date) else { return nil }
        let remaining = current.leaveTime.timeIntervalSince(date)
        return TimelineEntryRelevance(score: remaining < 300 ? 1.0 : 0.5)
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
        case .systemMedium: MediumWidgetView(entry: entry).widgetBackground(entry: entry, colorScheme: colorScheme)
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
            guard let data = entry.data else {
                return colorScheme == .dark ? Color(.systemBackground) : .white
            }
            if data.state == .fallback { return .orange }
            if data.state == .stale { return .gray }
            guard let current = data.connection(at: entry.date) else {
                return colorScheme == .dark ? Color(.systemBackground) : .white
            }
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            return urgencyColor(remaining)
        }()

        return containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    color.opacity(colorScheme == .dark ? 0.45 : 0.45), color.opacity(colorScheme == .dark ? 0.12 : 0.1),
                    .clear,
                ], startPoint: .trailing, endPoint: .leading
            )
        }
    }
}

// MARK: - SmallWidgetView

/// Focused on: When to leave, departure time, platform, and delay status
struct SmallWidgetView: View {
    let entry: GleisEntry
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if let data = entry.data, let current = data.connection(at: entry.date) {
            let conn = current.connection

            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    Text(widgetRouteText(for: entry, data: data))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.62)
                        .allowsTightening(true)

                    Text(widgetFirstWordRouteText(for: entry, data: data))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail) // falls back to automatic "..."
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                // Top: Line badge + alert icon (centered on one row)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    LineBadge(line: conn.lineNumber, lineColors: conn.lineColors, size: .small)
                    if conn.hasServiceAlert {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Service alert")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 6)

                Spacer(minLength: 0)

                // Center: Countdown - the hero element
                CountdownDisplay(
                    leaveTime: current.leaveTime,
                    referenceDate: entry.date,
                    size: .medium
                )

                Spacer(minLength: 0)

                // Bottom: Departure info - what you need at the station
                VStack(spacing: 4) {
                    DepartureInfo(connection: conn, size: .small)
                }
                .padding(.top, 6)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }.widgetURL(entryURL(entry, fallbackConnectionId: conn.id))
        } else {
            EmptyWidgetView(size: .small, data: entry.data)
        }
    }
}

// MARK: - MediumWidgetView

/// Journey card layout with countdown and departure details
struct MediumWidgetView: View {
    let entry: GleisEntry

    var body: some View {
        if let data = entry.data, let current = data.connection(at: entry.date) {
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            let conn = current.connection

            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    CountdownDisplay(
                        leaveTime: current.leaveTime,
                        referenceDate: entry.date,
                        size: .medium
                    )

                    if remaining > 0 {
                        Text("Leave at \(current.leaveTime, style: .time)").font(.system(size: 10)).foregroundStyle(
                            .secondary
                        ).scalableText(minimumScale: 0.8)
                    }
                }.frame(width: 88).frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Text(widgetRouteText(for: entry, data: data))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)

                    HStack(spacing: 8) {
                        LineBadge(line: conn.lineNumber, lineColors: conn.lineColors, size: .medium)

                        Text(conn.destination).font(.subheadline.weight(.semibold)).scalableText(minimumScale: 0.8)

                        Spacer()
                    }

                    HStack(spacing: 12) {
                        Text(timeFormatter.string(from: conn.departureTime))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .scalableText(minimumScale: 0.75)
                        Text("Platform \(conn.platform ?? "–")")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .scalableText(minimumScale: 0.75)
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        if conn.isDelayed {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.badge.exclamationmark").font(.caption2)
                                Text("+\(conn.delay) min").font(.caption.weight(.semibold))
                            }.foregroundStyle(.orange)
                        }
                        if conn.hasServiceAlert {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                                Text("Service alert").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }.padding(14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).widgetURL(
                entryURL(entry, fallbackConnectionId: conn.id))
        } else {
            EmptyWidgetView(size: .medium, data: entry.data)
        }
    }
}

// MARK: - CircularWidgetView

/// Pure countdown - just what you need at a glance
struct CircularWidgetView: View {
    let entry: GleisEntry

    var body: some View {
        if let data = entry.data, let current = data.connection(at: entry.date) {
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

                // Countdown
                VStack(spacing: 0) {
                    if remaining <= 0 {
                        Text("GO").font(.system(size: 18, weight: .black, design: .rounded)).scalableText(
                            minimumScale: 0.6)
                    } else if remaining <= 60 {
                        Text(current.leaveTime, style: .timer)
                            .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                            .multilineTextAlignment(.center)
                            .scalableText(minimumScale: 0.6)
                    } else {
                        Text("\(minutesRemaining(remaining)) m")
                            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            .multilineTextAlignment(.center)
                            .scalableText(minimumScale: 0.6)
                    }
                }
            }
            .widgetURL(entryURL(entry, fallbackConnectionId: current.connection.id))
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "tram.fill").font(.title3)
            }.widgetURL(entryURL(entry))
        }
    }
}

// MARK: - RectangularWidgetView

/// Clean 3-line layout with Apple-standard font sizes
struct RectangularWidgetView: View {
    let entry: GleisEntry

    var body: some View {
        if let data = entry.data, let current = data.connection(at: entry.date) {
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            let conn = current.connection

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: Route (origin -> destination)
                Text(widgetRouteText(for: entry, data: data))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)

                // Line 2: Train ID + departure/platform
                HStack(spacing: 6) {
                    Text(conn.lineNumber)
                        .font(.headline.weight(.bold))
                        .widgetAccentable()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(timeFormatter.string(from: conn.departureTime))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Pl \(conn.platform ?? "–")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                // Line 3: Countdown + status
                HStack(spacing: 4) {
                    if remaining <= 0 {
                        Text("GO!")
                            .font(.subheadline.weight(.semibold))
                            .widgetAccentable()
                            .scalableText(minimumScale: 0.8)
                    } else if remaining <= 60 {
                        Text(current.leaveTime, style: .timer)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .widgetAccentable()
                            .scalableText(minimumScale: 0.8)
                        Text("to go").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(minutesRemaining(remaining)) m")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .widgetAccentable()
                            .scalableText(minimumScale: 0.8)
                    }

                    if conn.isDelayed {
                        Text("+\(conn.delay)'")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }

                    if conn.hasServiceAlert {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }.widgetURL(entryURL(entry, fallbackConnectionId: conn.id))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "tram.fill").widgetAccentable()
                    Text("Gleis").fontWeight(.semibold)
                }.font(.headline)
                Text(emptyHintText(for: entry.data)).font(.subheadline).foregroundStyle(.secondary)
            }.widgetURL(entryURL(entry))
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
            case .small: .system(size: 12, weight: .bold)
            case .medium: .system(size: 14, weight: .bold)
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
            .scalableText(minimumScale: 0.7)
            .padding(.vertical, size.verticalPadding)
            .padding(.horizontal, size.horizontalPadding)
            .background(style.background, in: Capsule())
    }
}

// MARK: - CountdownDisplay

struct CountdownDisplay: View {
    let leaveTime: Date
    let referenceDate: Date
    let size: CountdownSize

    enum CountdownSize {
        case large, medium

        var mainFont: Font {
            switch self {
            case .large: .system(size: 44, weight: .bold, design: .rounded)
            case .medium: .system(size: 28, weight: .bold, design: .rounded)
            }
        }

        var labelFont: Font {
            switch self {
            case .large: .system(size: 12)
            case .medium: .system(size: 11)
            }
        }
    }

    var body: some View {
        let remaining = leaveTime.timeIntervalSince(referenceDate)
        VStack(spacing: 2) {
            if remaining <= 0 {
                Text("GO!").font(size.mainFont).foregroundStyle(.secondary).scalableText(minimumScale: 0.6)
            } else if remaining <= 60 {
                Text(leaveTime, style: .timer)
                    .font(size.mainFont.monospacedDigit())
                    .foregroundStyle(urgencyColor(remaining))
                    .multilineTextAlignment(.center)
                    .scalableText(minimumScale: 0.6)
                Text("leave now")
                    .font(size.labelFont.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(minutesRemaining(remaining)) m")
                    .font(size.mainFont.monospacedDigit())
                    .foregroundStyle(urgencyColor(remaining))
                    .multilineTextAlignment(.center)
                    .scalableText(minimumScale: 0.6)
                Text("to leave")
                    .font(size.labelFont.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - DepartureInfo

struct DepartureInfo: View {
    let connection: WidgetConnection
    let size: InfoSize
    private var displayPlatform: String {
        let trimmed = connection.platform?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "–" }
        return trimmed
    }

    enum InfoSize {
        case small, medium

        var labelFont: Font { .system(size: 9, weight: .semibold) }
        var departureLabel: String {
            switch self {
            case .small: "Departure"
            case .medium: "DEPARTURE"
            }
        }

        var platformLabel: String {
            switch self {
            case .small: "Platform"
            case .medium: "PLATFORM"
            }
        }

        var valueFont: Font {
            switch self {
            case .small: .headline.weight(.bold).monospacedDigit()
            case .medium: .title2.weight(.bold).monospacedDigit()
            }
        }

        var delayFont: Font {
            switch self {
            case .small: .system(size: 10, weight: .bold)
            case .medium: .caption.weight(.bold)
            }
        }
    }

    var body: some View {
        switch size {
        case .small:
            VStack(spacing: 4) {
                HStack(alignment: .top) {
                    departureColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    platformColumn(alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if connection.isDelayed {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Delay +\(connection.delay) m")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }

        case .medium:
            HStack(alignment: .top) {
                departureColumn
                Spacer()
                platformColumn(alignment: .trailing)
            }
        }
    }

    private var departureColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(size.departureLabel)
                .font(size.labelFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if connection.isDelayed {
                Text(timeFormatter.string(from: connection.departureTime))
                    .font(size.valueFont)
                    .foregroundStyle(.orange)
                    .scalableText(minimumScale: 0.7)
            } else {
                Text(timeFormatter.string(from: connection.departureTime)).font(size.valueFont).scalableText(
                    minimumScale: 0.7)
            }
        }
    }

    private func platformColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(size.platformLabel)
                .font(size.labelFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(displayPlatform).font(size.valueFont).scalableText(minimumScale: 0.7)
        }
    }
}

// MARK: - EmptyWidgetView

struct EmptyWidgetView: View {
    let size: EmptySize
    let data: WidgetData?

    enum EmptySize { case small, medium }

    var body: some View {
        let accentColor: Color = switch data?.state {
        case .fallback: .orange
        case .stale: .secondary
        default: .trainBlue
        }
        let hasSnapshot = data != nil
        let title = switch data?.state {
        case .fallback: "Offline data"
        case .stale: "No departures"
        default: hasSnapshot ? "No departures" : "Set up route"
        }
        let subtitle = emptyHintText(for: data)

        switch size {
        case .small:
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(accentColor.opacity(0.1)).frame(width: 48, height: 48)
                    Image(systemName: "tram.fill").font(.title3).foregroundStyle(accentColor)
                }
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).widgetURL(recoveryURL(for: data))

        case .medium:
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(accentColor.opacity(0.1)).frame(width: 56, height: 56)
                    Image(systemName: "tram.fill").font(.title2).foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }

                Spacer()
            } // .padding()
            .widgetURL(recoveryURL(for: data))
        }
    }
}

// MARK: - ScalableText

/// ViewModifier for scalable text that shrinks to fit available space
struct ScalableText: ViewModifier {
    let minimumScaleFactor: CGFloat

    init(minimumScaleFactor: CGFloat = 0.5) { self.minimumScaleFactor = minimumScaleFactor }

    func body(content: Content) -> some View { content.minimumScaleFactor(minimumScaleFactor).lineLimit(1) }
}

extension View {
    /// Makes text scalable, shrinking to fit available space if needed
    func scalableText(minimumScale: CGFloat = 0.5) -> some View {
        modifier(ScalableText(minimumScaleFactor: minimumScale))
    }
}

// MARK: - Helpers

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    return f
}()

private func widgetRouteText(for entry: GleisEntry, data: WidgetData) -> String {
    let from = normalizedWidgetStationName(data.fromStationName)
    let to = normalizedWidgetStationName(data.toStationName)
    if let from, let to { return "\(from) → \(to)" }
    return "From → To"
}

private func widgetFirstWordRouteText(for entry: GleisEntry, data: WidgetData) -> String {
    let from = normalizedWidgetStationName(data.fromStationName)
    let to = normalizedWidgetStationName(data.toStationName)
    if let from, let to {
        let fromCompact = from.components(separatedBy: .whitespaces).first ?? from
        let toCompact = to.components(separatedBy: .whitespaces).first ?? to
        return "\(fromCompact) → \(toCompact)"
    }
    return "From → To"
}

private func normalizedWidgetStationName(_ name: String?) -> String? {
    guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    return raw
}

private func entryURL(_ entry: GleisEntry, fallbackConnectionId: String? = nil) -> URL? {
    if let data = entry.data, data.state != .fresh, let url = recoveryURL(for: data) { return url }
    if let fallbackConnectionId { return connectionDeepLink(id: fallbackConnectionId) }
    return URL(string: "gleis://commute")
}

private func recoveryURL(for data: WidgetData?) -> URL? {
    guard let action = data?.recoveryAction else {
        if data == nil { return URL(string: "gleis://setup") }
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

private func emptyHintText(for data: WidgetData?) -> String {
    if let message = data?.stateMessage, !message.isEmpty { return message }
    switch data?.state {
    case .fallback:
        return "Open the app to refresh."
    case .stale:
        return "Check again soon or update route."
    default:
        return "Tap to set up your commute"
    }
}

private func minutesRemaining(_ remaining: TimeInterval) -> Int {
    max(1, Int(ceil(remaining / 60)))
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
