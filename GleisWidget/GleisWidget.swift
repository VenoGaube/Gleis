import AppIntents
import SwiftUI
import WidgetKit

// MARK: - SelectTransportIntent

struct SelectTransportIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configure Commute Widget"
    static var description: IntentDescription = "Choose route, direction, and day"

    @Parameter(title: "Transport Type", default: .trainCommute) var transportType: TransportTypeOption
    @Parameter(title: "Route", default: .liveRoute) var route: WidgetRouteOption
    @Parameter(title: "Direction", default: .forward) var direction: WidgetDirectionOption
    @Parameter(title: "Day", default: .today) var day: WidgetDayOption
}

// MARK: - TransportTypeOption

enum TransportTypeOption: String, AppEnum {
    case trainCommute = "Train"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Transport Type"
    static var caseDisplayRepresentations: [TransportTypeOption: DisplayRepresentation] = [
        .trainCommute: DisplayRepresentation(title: "Train", image: .init(systemName: "tram.fill")),
    ]

    var modelValue: TransportType { .trainCommute }
}

enum WidgetRouteOption: String, AppEnum {
    case repeatJourney = "Repeat Journey"
    case liveRoute = "Current Route"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Route"
    static var caseDisplayRepresentations: [WidgetRouteOption: DisplayRepresentation] = [
        .repeatJourney: DisplayRepresentation(title: "Repeat Journey", image: .init(systemName: "repeat")),
        .liveRoute: DisplayRepresentation(title: "Current Route", image: .init(systemName: "location")),
    ]

    var storageScope: WidgetRouteScope {
        switch self {
        case .repeatJourney: .repeatJourney
        case .liveRoute: .liveRoute
        }
    }
}

enum WidgetDirectionOption: String, AppEnum {
    case forward = "Forward"
    case reverse = "Reverse"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static var caseDisplayRepresentations: [WidgetDirectionOption: DisplayRepresentation] = [
        .forward: DisplayRepresentation(title: "From → To", image: .init(systemName: "arrow.right")),
        .reverse: DisplayRepresentation(title: "To → From", image: .init(systemName: "arrow.left")),
    ]

    var storageScope: WidgetDirectionScope {
        switch self {
        case .forward: .forward
        case .reverse: .reverse
        }
    }
}

enum WidgetDayOption: String, AppEnum {
    case today = "Today"
    case tomorrow = "Tomorrow"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Day"
    static var caseDisplayRepresentations: [WidgetDayOption: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today", image: .init(systemName: "calendar")),
        .tomorrow: DisplayRepresentation(title: "Tomorrow", image: .init(systemName: "calendar.badge.clock")),
    ]

    var storageScope: WidgetDayScope {
        switch self {
        case .today: .today
        case .tomorrow: .tomorrow
        }
    }
}

// MARK: - GleisProvider

struct GleisProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> GleisEntry {
        GleisEntry(date: Date(), data: WidgetData.placeholder, configuration: SelectTransportIntent())
    }

    func snapshot(for configuration: SelectTransportIntent, in _: Context) async -> GleisEntry {
        GleisEntry(date: Date(), data: loadData(for: configuration), configuration: configuration)
    }

    func timeline(for configuration: SelectTransportIntent, in _: Context) async -> Timeline<GleisEntry> {
        let data = loadData(for: configuration)
        let now = Date()
        var entries: [GleisEntry] = []

        // Explicit stale state should be surfaced to the user with a clear CTA.
        if let data, data.state == .stale {
            entries.append(GleisEntry(date: now, data: data, configuration: configuration))
            return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
        }

        if let data, let current = data.connection(at: now) {
            let remaining = current.leaveTime.timeIntervalSince(now)

            if remaining > 60 {
                // Create entries for each minute until we reach 1-minute timer mode
                let minutesUntilTimer = Int((remaining - 60) / 60) + 1
                for i in 0 ..< min(minutesUntilTimer, 30) {
                    entries.append(
                        GleisEntry(
                            date: now.addingTimeInterval(TimeInterval(i * 60)), data: data, configuration: configuration
                        ))
                }
                // Add entry at 1 minute before (when timer mode starts)
                entries.append(
                    GleisEntry(
                        date: current.leaveTime.addingTimeInterval(-60), data: data, configuration: configuration
                    ))
            } else if remaining > 0 {
                // Already in timer mode or about to leave
                entries.append(GleisEntry(date: now, data: data, configuration: configuration))
                entries.append(GleisEntry(date: current.leaveTime, data: data, configuration: configuration))
            } else {
                entries.append(GleisEntry(date: now, data: data, configuration: configuration))
            }

            // Add entries for the transition to next connection
            let nextConnectionDate = current.leaveTime.addingTimeInterval(1)
            if let nextCurrent = data.connection(at: nextConnectionDate) {
                entries.append(GleisEntry(date: nextConnectionDate, data: data, configuration: configuration))
                // Add entry for next connection's timer mode
                let nextRemaining = nextCurrent.leaveTime.timeIntervalSince(nextConnectionDate)
                if nextRemaining > 60 {
                    entries.append(
                        GleisEntry(
                            date: nextCurrent.leaveTime.addingTimeInterval(-60), data: data,
                            configuration: configuration
                        ))
                }
            }

            // Add an entry for when all connections will have departed (to show stale state)
            if let lastConn = data.connections.last {
                let staleDate = lastConn.departureTime.addingTimeInterval(1)
                if staleDate > now {
                    let staleData = staleData(
                        from: data,
                        updatedAt: staleDate,
                        message: "No more departures right now."
                    )
                    entries.append(GleisEntry(date: staleDate, data: staleData, configuration: configuration))
                }
            }
        } else if let data {
            // No current connection - check for future connections and create entries for them
            let futureConnections = data.futureConnections(from: now)

            if futureConnections.isEmpty {
                let staleData = staleData(
                    from: data,
                    updatedAt: now,
                    message: "No upcoming departures."
                )
                entries.append(GleisEntry(date: now, data: staleData, configuration: configuration))
            } else {
                entries.append(GleisEntry(date: now, data: data, configuration: configuration))

                // Find the first future leave time and create entries leading up to it
                for leaveTime in data.leaveTimes where leaveTime > now {
                    // Create entry 30 mins before leave time (when countdown becomes relevant)
                    let thirtyMinBefore = leaveTime.addingTimeInterval(-30 * 60)
                    if thirtyMinBefore > now {
                        entries.append(GleisEntry(date: thirtyMinBefore, data: data, configuration: configuration))
                    }
                    // Create entry at leave time minus 1 min (for timer mode)
                    let oneMinBefore = leaveTime.addingTimeInterval(-60)
                    if oneMinBefore > now {
                        entries.append(GleisEntry(date: oneMinBefore, data: data, configuration: configuration))
                    }
                    // Only handle first future connection
                    break
                }
            }
        } else {
            entries.append(GleisEntry(date: now, data: nil, configuration: configuration))
        }

        // Determine refresh policy
        let refreshPolicy: TimelineReloadPolicy
        if let data, let current = data.connection(at: now) {
            let remaining = current.leaveTime.timeIntervalSince(now)
            if remaining > 60 {
                // Refresh just before timer mode starts
                refreshPolicy = .after(current.leaveTime.addingTimeInterval(-59))
            } else if remaining > 0 {
                refreshPolicy = .after(current.leaveTime.addingTimeInterval(1))
            } else {
                refreshPolicy = .after(now.addingTimeInterval(60))
            }
        } else if let data, let firstFutureLeaveTime = data.leaveTimes.first(where: { $0 > now }) {
            // No current connection but have future ones - refresh 30 mins before next leave time
            let thirtyMinBefore = firstFutureLeaveTime.addingTimeInterval(-30 * 60)
            if thirtyMinBefore > now {
                refreshPolicy = .after(thirtyMinBefore)
            } else {
                refreshPolicy = .after(now.addingTimeInterval(300)) // 5 min refresh
            }
        } else {
            // No data or no future connections. Poll gently to recover.
            refreshPolicy = .after(now.addingTimeInterval(15 * 60))
        }

        return Timeline(entries: entries, policy: refreshPolicy)
    }

    private func loadData(for configuration: SelectTransportIntent) -> WidgetData? {
        let storageKey = WidgetDataStorageKey(
            transportType: configuration.transportType.modelValue,
            routeScope: configuration.route.storageScope,
            directionScope: configuration.direction.storageScope,
            dayScope: configuration.day.storageScope
        )
        return AppGroupStorage.loadWidgetData(for: storageKey)
    }

    private func staleData(from data: WidgetData, updatedAt: Date, message: String) -> WidgetData {
        WidgetData(
            transportType: data.transportType,
            connections: [],
            leaveTimes: [],
            fromStationName: data.fromStationName,
            toStationName: data.toStationName,
            updatedAt: updatedAt,
            state: .stale,
            stateMessage: message,
            recoveryAction: data.recoveryAction
        )
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
            return widgetJourneyUrgencyColor(remaining)
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

    var body: some View {
        if let data = entry.data, let current = data.connection(at: entry.date) {
            let route = widgetRouteText(for: entry, data: data)
            WidgetJourneySmallCardContent(
                routeText: route,
                connection: current.connection,
                leaveTime: current.leaveTime,
                referenceDate: entry.date
            )
            .widgetURL(entryURL(entry, fallbackConnectionId: current.connection.id))
        } else {
            WidgetJourneyEmptyState(size: .small, data: entry.data, subtitle: emptyHintText(for: entry.data))
                .widgetURL(recoveryURL(for: entry.data))
        }
    }
}

// MARK: - MediumWidgetView

/// Journey card layout with countdown and departure details
struct MediumWidgetView: View {
    let entry: GleisEntry

    var body: some View {
        if let data = entry.data, let current = data.connection(at: entry.date) {
            let route = widgetRouteText(for: entry, data: data)
            WidgetJourneyMediumCardContent(
                routeText: route,
                connection: current.connection,
                leaveTime: current.leaveTime,
                referenceDate: entry.date
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(entryURL(entry, fallbackConnectionId: current.connection.id))
        } else {
            WidgetJourneyEmptyState(size: .medium, data: entry.data, subtitle: emptyHintText(for: entry.data))
                .widgetURL(recoveryURL(for: entry.data))
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
                    } else if widgetShouldShowSecondsCountdown(leaveTime: current.leaveTime) {
                        // Under 1 minute: live countdown with seconds
                        Text(current.leaveTime, style: .timer).font(
                            .system(size: 14, weight: .bold, design: .rounded).monospacedDigit()
                        ).multilineTextAlignment(.center).scalableText(minimumScale: 0.6)
                    } else {
                        Text("\(Int(ceil(remaining / 60)))").font(
                            .system(size: 20, weight: .bold, design: .rounded).monospacedDigit()
                        ).scalableText(minimumScale: 0.6)
                        Text("min").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }.widgetURL(entryURL(entry, fallbackConnectionId: current.connection.id))
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

            VStack(alignment: .leading, spacing: 1) {
                // Line 1: Line number + Destination
                HStack(spacing: 5) {
                    Text(widgetCompactRouteText(for: entry, data: data))
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .scalableText(minimumScale: 0.7)
                    Text("•").foregroundStyle(.secondary)
                    Text(conn.lineNumber).fontWeight(.bold).widgetAccentable()
                    Text(conn.destination).scalableText(minimumScale: 0.8)
                }.font(.headline)

                // Line 2: Departure time + Platform
                HStack(spacing: 5) {
                    Text(timeFormatter.string(from: conn.departureTime)).fontWeight(.semibold).scalableText(
                        minimumScale: 0.8)
                    if conn.isDelayed { Text("+\(conn.delay)'").foregroundStyle(.orange) }
                    if conn.hasServiceAlert {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Text("•").foregroundStyle(.secondary)
                    Text("Pl. \(conn.platform ?? "–")").fontWeight(.semibold).scalableText(minimumScale: 0.8)
                }.font(.subheadline)

                // Line 3: Countdown
                HStack(spacing: 4) {
                    if remaining <= 0 {
                        Text("GO!").fontWeight(.semibold).widgetAccentable().scalableText(minimumScale: 0.8)
                    } else if widgetShouldShowSecondsCountdown(leaveTime: current.leaveTime) {
                        // Under 1 minute: live countdown with seconds
                        Text(current.leaveTime, style: .timer).fontWeight(.bold).widgetAccentable().scalableText(
                            minimumScale: 0.8)
                        Text("to go").foregroundStyle(.secondary)
                    } else {
                        Text(widgetJourneyFormatCountdown(remaining)).fontWeight(.bold).widgetAccentable().scalableText(
                            minimumScale: 0.8)
                        Text("to go").foregroundStyle(.secondary)
                    }
                }.font(.subheadline)
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
    return entry.configuration.direction == .forward ? "From → To" : "To → From"
}

private func widgetCompactRouteText(for entry: GleisEntry, data: WidgetData) -> String {
    let from = normalizedWidgetStationName(data.fromStationName)
    let to = normalizedWidgetStationName(data.toStationName)
    if let from, let to {
        let fromCompact = from.components(separatedBy: .whitespaces).first ?? from
        let toCompact = to.components(separatedBy: .whitespaces).first ?? to
        return "\(fromCompact)→\(toCompact)"
    }
    return entry.configuration.direction == .forward ? "F→T" : "T→F"
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

    static func lineColor(for line: String, apiColors: TrainLineColors?) -> Color {
        lineBadgeStyle(for: line, apiColors: apiColors).background
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
