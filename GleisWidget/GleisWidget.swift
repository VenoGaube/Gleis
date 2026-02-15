import AppIntents
import SwiftUI
import WidgetKit

// MARK: - SelectTransportIntent

struct SelectTransportIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Transport"
    static var description: IntentDescription = "Choose which transport to display"

    @Parameter(title: "Transport Type", default: .trainCommute) var transportType: TransportTypeOption
}

// MARK: - TransportTypeOption

enum TransportTypeOption: String, AppEnum {
    case trainCommute = "Train"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Transport Type"
    static var caseDisplayRepresentations: [TransportTypeOption: DisplayRepresentation] = [
        .trainCommute: DisplayRepresentation(title: "Train", image: .init(systemName: "tram.fill")),
    ]
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

        // Check if data is stale (all connections departed or data too old)
        // If stale, show empty state and request refresh soon
        if let data, data.isStale {
            entries.append(GleisEntry(date: now, data: nil, configuration: configuration))
            // Request refresh as soon as possible when data is stale
            return Timeline(entries: entries, policy: .atEnd)
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
                    // Pass nil data to show empty/stale state after last train departs
                    entries.append(GleisEntry(date: staleDate, data: nil, configuration: configuration))
                }
            }
        } else if let data {
            // No current connection - check for future connections and create entries for them
            let futureConnections = data.futureConnections(from: now)

            if futureConnections.isEmpty {
                // All connections have departed - show empty state
                entries.append(GleisEntry(date: now, data: nil, configuration: configuration))
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
            // No data or no future connections - request refresh immediately
            // This helps recover from stale data when phone unlocks
            refreshPolicy = .atEnd
        }

        return Timeline(entries: entries, policy: refreshPolicy)
    }

    private func loadData() -> WidgetData? { AppGroupStorage.loadWidgetData(for: .trainCommute) }
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
            guard let data = entry.data, let current = data.connection(at: entry.date) else {
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
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            let conn = current.connection

            VStack(spacing: 0) {
                // Top: Line badge (centered)
                LineBadge(line: conn.lineNumber, lineColors: conn.lineColors, size: .small).padding(.top, 12)

                Spacer(minLength: 0)

                // Center: Countdown - the hero element
                CountdownDisplay(remaining: remaining, leaveTime: current.leaveTime, size: .medium)

                Spacer(minLength: 0)

                // Bottom: Departure info - what you need at the station
                DepartureInfo(connection: conn, size: .small).padding(.horizontal, 12).padding(.bottom, 12)
            }.widgetURL(URL(string: "gleis://connection?id=\(conn.id)"))
        } else {
            EmptyWidgetView(size: .small)
        }
    }
}

// MARK: - MediumWidgetView

/// Journey card layout with countdown and departure details
struct MediumWidgetView: View {
    let entry: GleisEntry
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if let data = entry.data, let current = data.connection(at: entry.date) {
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            let conn = current.connection

            HStack(spacing: 0) {
                // Left: Countdown panel
                VStack(spacing: 4) {
                    CountdownDisplay(remaining: remaining, leaveTime: current.leaveTime, size: .medium)

                    if remaining > 0 {
                        Text("Leave at \(current.leaveTime, style: .time)").font(.system(size: 10)).foregroundStyle(
                            .secondary
                        ).scalableText(minimumScale: 0.8)
                    }
                }.frame(width: 95).frame(maxHeight: .infinity)

                // Right: Journey details
                VStack(alignment: .leading, spacing: 8) {
                    // Header: Line + Destination
                    HStack(spacing: 8) {
                        LineBadge(line: conn.lineNumber, lineColors: conn.lineColors, size: .medium)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(conn.destination).font(.subheadline.weight(.semibold)).scalableText(minimumScale: 0.8)

                            if conn.isPinned {
                                HStack(spacing: 2) {
                                    Image(systemName: "pin.fill").font(.system(size: 7))
                                    Text("MY JOURNEY").font(.system(size: 7, weight: .semibold))
                                }.foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
                    }

                    Spacer(minLength: 0)

                    // Departure time + Platform (the critical info)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DEPARTURE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)

                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if conn.isDelayed {
                                    Text(scheduledTime(conn.departureTime, delay: conn.delay)).font(
                                        .title3.weight(.medium).monospacedDigit()
                                    ).strikethrough().foregroundStyle(.secondary).scalableText(minimumScale: 0.7)

                                    Text(timeFormatter.string(from: conn.departureTime)).font(
                                        .title2.weight(.bold).monospacedDigit()
                                    ).foregroundStyle(.orange).scalableText(minimumScale: 0.7)
                                } else {
                                    Text(timeFormatter.string(from: conn.departureTime)).font(
                                        .title2.weight(.bold).monospacedDigit()
                                    ).scalableText(minimumScale: 0.7)
                                }
                            }
                        }

                        Spacer()

                        // Platform - same height as departure
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("PLATFORM").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)

                            Text(conn.platform ?? "–").font(.title2.weight(.bold).monospacedDigit()).scalableText(
                                minimumScale: 0.7)
                        }
                    }

                    // Delay indicator
                    if conn.isDelayed {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                            Text("+\(conn.delay) min delay").font(.caption.weight(.medium))
                        }.foregroundStyle(.orange)
                    }
                }.padding(14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).widgetURL(
                URL(string: "gleis://connection?id=\(conn.id)"))
        } else {
            EmptyWidgetView(size: .medium)
        }
    }

    private func scheduledTime(_ actual: Date, delay: Int) -> String {
        let scheduled = actual.addingTimeInterval(TimeInterval(-delay * 60))
        return timeFormatter.string(from: scheduled)
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
                        // Under 1 minute: live countdown with seconds
                        Text(current.leaveTime, style: .timer).font(
                            .system(size: 14, weight: .bold, design: .rounded).monospacedDigit()
                        ).multilineTextAlignment(.center).scalableText(minimumScale: 0.6)
                    } else {
                        Text("\(Int(ceil(remaining / 60)))").font(
                            .system(size: 20, weight: .bold, design: .rounded).monospacedDigit()
                        ).scalableText(minimumScale: 0.6)
                        Text("min").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }.widgetURL(URL(string: "gleis://commute"))
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "tram.fill").font(.title3)
            }.widgetURL(URL(string: "gleis://commute"))
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
                    Text(conn.lineNumber).fontWeight(.bold).widgetAccentable()
                    Text(conn.destination).scalableText(minimumScale: 0.8)
                }.font(.headline)

                // Line 2: Departure time + Platform
                HStack(spacing: 5) {
                    Text(timeFormatter.string(from: conn.departureTime)).fontWeight(.semibold).scalableText(
                        minimumScale: 0.8)
                    if conn.isDelayed { Text("+\(conn.delay)'").foregroundStyle(.orange) }
                    Text("•").foregroundStyle(.secondary)
                    Text("Pl. \(conn.platform ?? "–")").fontWeight(.semibold).scalableText(minimumScale: 0.8)
                }.font(.subheadline)

                // Line 3: Countdown
                HStack(spacing: 4) {
                    if remaining <= 0 {
                        Text("GO!").fontWeight(.semibold).widgetAccentable().scalableText(minimumScale: 0.8)
                    } else if remaining <= 60 {
                        // Under 1 minute: live countdown with seconds
                        Text(current.leaveTime, style: .timer).fontWeight(.bold).widgetAccentable().scalableText(
                            minimumScale: 0.8)
                        Text("to go").foregroundStyle(.secondary)
                    } else {
                        Text(formatCountdown(remaining)).fontWeight(.bold).widgetAccentable().scalableText(
                            minimumScale: 0.8)
                        Text("to go").foregroundStyle(.secondary)
                    }
                }.font(.subheadline)
            }.widgetURL(URL(string: "gleis://commute"))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "tram.fill").widgetAccentable()
                    Text("Gleis").fontWeight(.semibold)
                }.font(.headline)
                Text("Tap to set up route").font(.subheadline).foregroundStyle(.secondary)
            }.widgetURL(URL(string: "gleis://setup"))
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
    let remaining: TimeInterval
    let leaveTime: Date
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
            case .medium: .system(size: 10)
            }
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            if remaining <= 0 {
                Text("GO!").font(size.mainFont).foregroundStyle(.secondary).scalableText(minimumScale: 0.6)
            } else if remaining <= 60 {
                // Under 1 minute: live countdown timer with seconds
                Text(leaveTime, style: .timer).font(size.mainFont.monospacedDigit()).foregroundStyle(
                    urgencyColor(remaining)
                ).multilineTextAlignment(.center).scalableText(minimumScale: 0.6)
                Text("leave now").font(size.labelFont.weight(.medium)).foregroundStyle(.secondary)
            } else {
                Text(formatCountdown(remaining)).font(size.mainFont.monospacedDigit()).foregroundStyle(
                    urgencyColor(remaining)
                ).scalableText(minimumScale: 0.6)
                Text("to leave").font(size.labelFont.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - DepartureInfo

struct DepartureInfo: View {
    let connection: WidgetConnection
    let size: InfoSize

    enum InfoSize {
        case small, medium

        var labelFont: Font { .system(size: 9, weight: .semibold) }
        var departureLabel: String {
            switch self {
            case .small: "DEP"
            case .medium: "DEPARTURE"
            }
        }

        var platformLabel: String {
            switch self {
            case .small: "PL"
            case .medium: "PLATFORM"
            }
        }

        var valueFont: Font {
            switch self {
            case .small: .subheadline.weight(.bold).monospacedDigit()
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
        HStack(alignment: .top) {
            // Departure time
            VStack(alignment: .leading, spacing: 2) {
                Text(size.departureLabel).font(size.labelFont).foregroundStyle(.secondary)

                if connection.isDelayed {
                    HStack(spacing: 4) {
                        Text(timeFormatter.string(from: connection.departureTime)).font(size.valueFont).foregroundStyle(
                            .orange
                        ).scalableText(minimumScale: 0.7)
                        Text("+\(connection.delay)'").font(size.delayFont).foregroundStyle(.orange)
                    }
                } else {
                    Text(timeFormatter.string(from: connection.departureTime)).font(size.valueFont).scalableText(
                        minimumScale: 0.7)
                }
            }

            Spacer()

            // Platform
            VStack(alignment: .trailing, spacing: 2) {
                Text(size.platformLabel).font(size.labelFont).foregroundStyle(.secondary)
                Text(connection.platform ?? "–").font(size.valueFont).scalableText(minimumScale: 0.7)
            }
        }
    }
}

// MARK: - EmptyWidgetView

struct EmptyWidgetView: View {
    let size: EmptySize

    enum EmptySize { case small, medium }

    var body: some View {
        switch size {
        case .small:
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.trainBlue.opacity(0.1)).frame(width: 48, height: 48)
                    Image(systemName: "tram.fill").font(.title3).foregroundStyle(Color.trainBlue)
                }
                Text("Set up route").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).widgetURL(URL(string: "gleis://setup"))

        case .medium:
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.trainBlue.opacity(0.1)).frame(width: 56, height: 56)
                    Image(systemName: "tram.fill").font(.title2).foregroundStyle(Color.trainBlue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("No Route Configured").font(.headline)
                    Text("Tap to set up your commute").font(.subheadline).foregroundStyle(.secondary)
                }

                Spacer()
            } // .padding()
            .widgetURL(URL(string: "gleis://setup"))
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

private func formatCountdown(_ seconds: TimeInterval) -> String {
    // Truncate to show remaining time (0m appears in final minute)
    let totalMinutes = Int(ceil(max(0, seconds) / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 {
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
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
