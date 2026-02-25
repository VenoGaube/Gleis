import SwiftUI

enum WidgetJourneyBadgeSize {
    case small
    case medium

    var font: Font {
        switch self {
        case .small:
            return .system(size: 12, weight: .bold)
        case .medium:
            return .system(size: 14, weight: .bold)
        }
    }

    var verticalPadding: CGFloat { self == .small ? 4 : 5 }
    var horizontalPadding: CGFloat { self == .small ? 8 : 10 }
}

enum WidgetJourneyCountdownSize {
    case medium

    var mainFont: Font { .system(size: 28, weight: .bold, design: .rounded) }
    var labelFont: Font { .system(size: 10) }
}

enum WidgetJourneyInfoSize {
    case small
    case medium

    var labelFont: Font { .system(size: 9, weight: .semibold) }
    var departureLabel: String { self == .small ? "DEP" : "DEPARTURE" }
    var platformLabel: String { self == .small ? "PL" : "PLATFORM" }

    var valueFont: Font {
        self == .small
            ? .subheadline.weight(.bold).monospacedDigit()
            : .title2.weight(.bold).monospacedDigit()
    }

    var delayFont: Font {
        self == .small
            ? .system(size: 10, weight: .bold)
            : .caption.weight(.bold)
    }
}

enum WidgetJourneyEmptySize {
    case small
    case medium
}

private let widgetJourneyTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
}()

func widgetJourneyFormatCountdown(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int(ceil(max(0, seconds) / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 {
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

func widgetJourneyUrgencyColor(_ remaining: TimeInterval) -> Color {
    if remaining <= 0 { return .secondary }
    if remaining < 120 { return .red }
    if remaining < 300 { return .orange }
    return .green
}

func widgetShouldShowSecondsCountdown(leaveTime: Date) -> Bool {
    let remaining = leaveTime.timeIntervalSinceNow
    return remaining > 0 && remaining <= 60
}

private func widgetJourneyScheduledTime(_ actual: Date, delay: Int) -> String {
    let scheduled = actual.addingTimeInterval(TimeInterval(-delay * 60))
    return widgetJourneyTimeFormatter.string(from: scheduled)
}

struct WidgetJourneyLineBadge: View {
    let line: String
    let lineColors: TrainLineColors?
    let size: WidgetJourneyBadgeSize

    var body: some View {
        Text(line)
            .font(size.font)
            .foregroundStyle(.white)
            .scalableText(minimumScale: 0.7)
            .padding(.vertical, size.verticalPadding)
            .padding(.horizontal, size.horizontalPadding)
            .background(Color.lineColor(for: line, apiColors: lineColors), in: Capsule())
    }
}

struct WidgetJourneyCountdownDisplay: View {
    let remaining: TimeInterval
    let leaveTime: Date
    let size: WidgetJourneyCountdownSize

    var body: some View {
        let liveRemaining = leaveTime.timeIntervalSinceNow

        VStack(spacing: 2) {
            if liveRemaining <= 0 {
                Text("GO!")
                    .font(size.mainFont)
                    .foregroundStyle(.secondary)
                    .scalableText(minimumScale: 0.6)
            } else if widgetShouldShowSecondsCountdown(leaveTime: leaveTime) {
                Text(leaveTime, style: .timer)
                    .font(size.mainFont.monospacedDigit())
                    .foregroundStyle(widgetJourneyUrgencyColor(liveRemaining))
                    .multilineTextAlignment(.center)
                    .scalableText(minimumScale: 0.6)
                Text("leave now")
                    .font(size.labelFont.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(widgetJourneyFormatCountdown(max(remaining, liveRemaining)))
                    .font(size.mainFont.monospacedDigit())
                    .foregroundStyle(widgetJourneyUrgencyColor(max(remaining, liveRemaining)))
                    .scalableText(minimumScale: 0.6)
                Text("to leave")
                    .font(size.labelFont.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WidgetJourneyDepartureInfo: View {
    let connection: WidgetConnection
    let size: WidgetJourneyInfoSize

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(size.departureLabel)
                    .font(size.labelFont)
                    .foregroundStyle(.secondary)

                if connection.isDelayed {
                    HStack(spacing: 4) {
                        Text(widgetJourneyTimeFormatter.string(from: connection.departureTime))
                            .font(size.valueFont)
                            .foregroundStyle(.orange)
                            .scalableText(minimumScale: 0.7)
                        Text("+\(connection.delay)'")
                            .font(size.delayFont)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(widgetJourneyTimeFormatter.string(from: connection.departureTime))
                        .font(size.valueFont)
                        .scalableText(minimumScale: 0.7)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(size.platformLabel)
                    .font(size.labelFont)
                    .foregroundStyle(.secondary)
                Text(connection.platform ?? "–")
                    .font(size.valueFont)
                    .scalableText(minimumScale: 0.7)
            }
        }
    }
}

struct WidgetJourneySmallCardContent: View {
    let routeText: String
    let connection: WidgetConnection
    let leaveTime: Date
    let referenceDate: Date

    private var remaining: TimeInterval { leaveTime.timeIntervalSince(referenceDate) }

    var body: some View {
        VStack(spacing: 0) {
            Text(routeText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.62)
                .allowsTightening(true)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            WidgetJourneyLineBadge(line: connection.lineNumber, lineColors: connection.lineColors, size: .small)
                .padding(.top, 6)

            Spacer(minLength: 0)

            WidgetJourneyCountdownDisplay(remaining: remaining, leaveTime: leaveTime, size: .medium)

            Spacer(minLength: 0)

            VStack(spacing: 4) {
                WidgetJourneyDepartureInfo(connection: connection, size: .small)
                if connection.hasServiceAlert {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Service alert")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

struct WidgetJourneyMediumCardContent: View {
    let routeText: String
    let connection: WidgetConnection
    let leaveTime: Date
    let referenceDate: Date

    private var remaining: TimeInterval { leaveTime.timeIntervalSince(referenceDate) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                WidgetJourneyCountdownDisplay(remaining: remaining, leaveTime: leaveTime, size: .medium)

                if remaining > 0 {
                    Text("Leave at \(leaveTime, style: .time)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .scalableText(minimumScale: 0.8)
                }
            }
            .frame(width: 95)
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text(routeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)

                HStack(spacing: 8) {
                    WidgetJourneyLineBadge(line: connection.lineNumber, lineColors: connection.lineColors, size: .medium)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.destination)
                            .font(.subheadline.weight(.semibold))
                            .scalableText(minimumScale: 0.8)

                        if connection.isPinned {
                            HStack(spacing: 2) {
                                Image(systemName: "pin.fill").font(.system(size: 7))
                                Text("MY JOURNEY").font(.system(size: 7, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }

                Spacer(minLength: 0)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DEPARTURE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if connection.isDelayed {
                                Text(widgetJourneyScheduledTime(connection.departureTime, delay: connection.delay))
                                    .font(.title3.weight(.medium).monospacedDigit())
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                    .scalableText(minimumScale: 0.7)

                                Text(widgetJourneyTimeFormatter.string(from: connection.departureTime))
                                    .font(.title2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.orange)
                                    .scalableText(minimumScale: 0.7)
                            } else {
                                Text(widgetJourneyTimeFormatter.string(from: connection.departureTime))
                                    .font(.title2.weight(.bold).monospacedDigit())
                                    .scalableText(minimumScale: 0.7)
                            }
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("PLATFORM")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(connection.platform ?? "–")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .scalableText(minimumScale: 0.7)
                    }
                }

                if connection.isDelayed {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                        Text("+\(connection.delay) min delay").font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.orange)
                }

                if connection.hasServiceAlert {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                        Text("Service alert").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.red)
                }
            }
            .padding(14)
        }
    }
}

struct WidgetJourneyEmptyState: View {
    let size: WidgetJourneyEmptySize
    let data: WidgetData?
    let subtitle: String

    private var accentColor: Color {
        switch data?.state {
        case .fallback: return .orange
        case .stale: return .secondary
        default: return .trainBlue
        }
    }

    private var title: String {
        switch data?.state {
        case .fallback: return "Offline data"
        case .stale: return "No departures"
        default: return "Set up route"
        }
    }

    var body: some View {
        switch size {
        case .small:
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(accentColor.opacity(0.1)).frame(width: 48, height: 48)
                    Image(systemName: "tram.fill").font(.title3).foregroundStyle(accentColor)
                }
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            }
        }
    }
}
