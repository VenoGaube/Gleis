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
            let isUnreadable = AppGroupStorage.isPrimaryWidgetSnapshotUnreadable(for: .trainCommute)
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
                configuration: configuration
            )
        }

        return Timeline(
            entries: entries,
            policy: timelineReloadPolicy(now: now, data: data, entryCount: entries.count)
        )
    }

    private func loadData() -> WidgetData? {
        AppGroupStorage.loadPrimaryWidgetData(for: .trainCommute)
    }

    // MARK: - Entry Scheduling

    /// The instants at which the rendered widget actually changes.
    ///
    /// Sub-minute countdowns are deliberately absent: the views use
    /// `Text(_:style: .timer)` inside the final minute, which updates itself without
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

    init(date: Date, snapshot: WidgetRenderSnapshot?, configuration: SelectTransportIntent) {
        self.date = date
        self.snapshot = snapshot
        self.configuration = configuration
    }

    /// Convenience for call sites that still hold a full snapshot (placeholders, previews).
    init(date: Date, data: WidgetData?, configuration: SelectTransportIntent) {
        self.init(date: date, snapshot: data?.renderSnapshot(at: date), configuration: configuration)
    }

    var relevance: TimelineEntryRelevance? {
        guard let leaveTime = snapshot?.leaveTime else { return nil }
        let remaining = leaveTime.timeIntervalSince(date)
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
        if let data = entry.snapshot, let current = data.scheduled {
            let conn = current.connection

            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    Text(data.routeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.62)
                        .allowsTightening(true)

                    Text(data.compactRouteText)
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
                    if conn.isCancelled {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Service cancelled")
                    } else if conn.hasServiceAlert {
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
            EmptyWidgetView(size: .small, snapshot: entry.snapshot)
        }
    }
}

// MARK: - MediumWidgetView

/// Journey card layout with countdown and departure details
struct MediumWidgetView: View {
    let entry: GleisEntry

    var body: some View {
        if let data = entry.snapshot, let current = data.scheduled {
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
                    Text(data.routeText)
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
                        if conn.isCancelled {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.octagon.fill").font(.caption2)
                                Text("Cancelled").font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.red)
                        } else {
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
                    }
                }.padding(14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).widgetURL(
                entryURL(entry, fallbackConnectionId: conn.id))
        } else {
            EmptyWidgetView(size: .medium, snapshot: entry.snapshot)
        }
    }
}

// MARK: - CircularWidgetView

/// Pure countdown - just what you need at a glance
struct CircularWidgetView: View {
    let entry: GleisEntry

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
                        Text("\(minutesRemaining(remaining))")
                            .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                            .multilineTextAlignment(.center)
                            .scalableText(minimumScale: 0.6)
                        Text("min")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
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
        if let data = entry.snapshot, let current = data.scheduled {
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            let conn = current.connection

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: Route (origin -> destination)
                Text(data.routeText)
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
                        Text("\(minutesRemaining(remaining))m")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .widgetAccentable()
                            .scalableText(minimumScale: 0.8)
                    }

                    if conn.isCancelled {
                        Text("Cancelled")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                    } else {
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
                }
            }.widgetURL(entryURL(entry, fallbackConnectionId: conn.id))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "tram.fill").widgetAccentable()
                    Text("Gleis").fontWeight(.semibold)
                }.font(.headline)
                Text(entry.snapshot?.emptyHintText ?? WidgetRenderSnapshot.missingHintText)
                    .font(.subheadline).foregroundStyle(.secondary)
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
                Text("\(minutesRemaining(remaining))m")
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
    let snapshot: WidgetRenderSnapshot?

    enum EmptySize { case small, medium }

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
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(accentColor.opacity(0.1)).frame(width: 48, height: 48)
                    Image(systemName: "tram.fill").font(.title3).foregroundStyle(accentColor)
                }
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).widgetURL(recoveryURL(for: snapshot))

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
            .widgetURL(recoveryURL(for: snapshot))
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
