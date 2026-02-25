import SwiftUI

// MARK: - ConnectionCard

struct ConnectionCard: View {
    let displayConnection: DisplayConnection
    let onSchedule: () -> Void
    let onCancel: () -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void
    let onTap: () -> Void
    let showLayoutDebug: Bool

    init(
        displayConnection: DisplayConnection,
        onSchedule: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onUnpin: @escaping () -> Void,
        onTap: @escaping () -> Void,
        showLayoutDebug: Bool = false
    ) {
        self.displayConnection = displayConnection
        self.onSchedule = onSchedule
        self.onCancel = onCancel
        self.onPin = onPin
        self.onUnpin = onUnpin
        self.onTap = onTap
        self.showLayoutDebug = showLayoutDebug
    }

    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false

    // Convenience accessors
    private var connection: TrainConnection { displayConnection.connection }
    private var leaveTime: Date { displayConnection.leaveTime }
    private var timeRemaining: TimeInterval { displayConnection.timeRemaining }
    private var urgencyColor: Color { displayConnection.urgencyColor }
    private var progress: Double { displayConnection.progress }
    private var isMissed: Bool { displayConnection.isMissed }
    private var isSelected: Bool { displayConnection.isSelected }
    private var isPinned: Bool { displayConnection.isPinned }
    private var scheduledDepartureTime: Date? {
        guard connection.delay > 0 else { return nil }
        return connection.departureTime.addingTimeInterval(TimeInterval(-connection.delay * 60))
    }
    private var scheduledArrivalTime: Date? {
        guard connection.delay > 0 else { return nil }
        return connection.arrivalTime.addingTimeInterval(TimeInterval(-connection.delay * 60))
    }

    var body: some View {
        cardContent
            .background(cardBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
            .overlay(cardBorder)
            .shadow(color: shadowColor, radius: 8, y: 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if isMissed { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } } else { onTap() }
            }
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            if isMissed, !isExpanded {
                compactMissedView
            } else {
                headerSection
                Divider().background(dividerColor).padding(.horizontal, 16)
                timeInfoSection
                leaveTimeSection
            }
        }
    }

    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground)
    }

    private var cardCornerRadius: CGFloat {
        isMissed && !isExpanded ? 12 : 16
    }

    private var dividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)
    }

    private var cardBorder: some View {
        let strokeColor = isSelected
            ? Color.accentColor
            : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.15))
        return RoundedRectangle(cornerRadius: cardCornerRadius)
            .stroke(strokeColor, lineWidth: isSelected ? 2 : 1)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .clear : .black.opacity(0.05)
    }

    private var compactMissedView: some View {
        HStack(spacing: 12) {
            LineBadge(line: connection.lineNumber, colors: connection.lineColors)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.arrivalStation.name).font(.subheadline.weight(.medium)).scalableText(minimumScale: 0.8)
                Text(connection.departureTime, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("GO!").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).padding(.vertical, 12).opacity(0.6).debugLayoutBox(showLayoutDebug, color: .gray)
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            LineBadge(line: connection.lineNumber, colors: connection.lineColors).debugLayoutBox(
                showLayoutDebug,
                color: .indigo
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.departureStation.name).font(.subheadline.weight(.medium)).scalableText(
                        minimumScale: 0.8)
                    if isPinned { PinBadge() }
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.caption2)
                    Text(connection.arrivalStation.name).font(.caption).scalableText(minimumScale: 0.8)
                }.foregroundStyle(.secondary)
            }.debugLayoutBox(showLayoutDebug, color: .mint)
            Spacer()
            headerStatusBadges.debugLayoutBox(showLayoutDebug, color: .pink)
        }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12).debugLayoutBox(showLayoutDebug, color: .blue)
    }

    @ViewBuilder
    private var headerStatusBadges: some View {
        if connection.hasServiceAlerts, connection.isDelayed {
            VStack(alignment: .trailing, spacing: 6) {
                ServiceAlertBadge()
                DelayBadge(minutes: connection.delay)
            }
        } else if connection.hasServiceAlerts {
            ServiceAlertBadge()
                .frame(minHeight: 40, alignment: .center)
        } else if connection.isDelayed {
            DelayBadge(minutes: connection.delay)
                .frame(minHeight: 40, alignment: .center)
        }
    }

    private var timeInfoSection: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                VStack(spacing: 6) {
                    Text("DEPARTS")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let scheduledDepartureTime {
                        VStack(spacing: 2) {
                            Text(scheduledDepartureTime, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .strikethrough()
                            Text(connection.departureTime, style: .time)
                                .font(.headline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text(connection.departureTime, style: .time)
                            .font(.headline.weight(.semibold).monospacedDigit())
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(minWidth: 66, alignment: .center)
                .layoutPriority(2)
                .debugLayoutBox(showLayoutDebug, color: .cyan)
                VStack(spacing: 6) {
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text("\(Int(connection.duration / 60)) min").font(.caption2).foregroundStyle(.secondary)
                    if let stops = connection.totalStopCount, stops > 0 {
                        Text("\(stops) \(stops == 1 ? "stop" : "stops")")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .multilineTextAlignment(.center)
                    }
                    if connection.transfers == 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Direct")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .accessibilityLabel("Direct connection with no transfers")
                    } else {
                        HStack(spacing: 3) {
                            Text("\(connection.transfers)")
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(connection.transfers >= 2 ? .red : .orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (connection.transfers >= 2 ? Color.red : Color.orange).opacity(0.15),
                            in: Capsule()
                        )
                        .accessibilityLabel(
                            connection.transfers == 1
                                ? "1 transfer"
                                : "\(connection.transfers) transfers"
                        )
                    }

                }
                .frame(minWidth: 64, maxWidth: .infinity)
                .debugLayoutBox(showLayoutDebug, color: .orange)
                VStack(spacing: 6) {
                    Text("ARRIVES")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let scheduledArrivalTime {
                        VStack(spacing: 2) {
                            Text(scheduledArrivalTime, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .strikethrough()
                            Text(connection.arrivalTime, style: .time)
                                .font(.headline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text(connection.arrivalTime, style: .time)
                            .font(.headline.weight(.semibold).monospacedDigit())
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(minWidth: 66, alignment: .center)
                .layoutPriority(2)
                .debugLayoutBox(showLayoutDebug, color: .green)
            }.frame(maxWidth: .infinity)
            Divider().frame(height: 40).padding(2)
            VStack(spacing: 2) {
                Text("Platform").font(.caption2).foregroundStyle(.secondary)
                Text(connection.platform ?? "—").font(
                    connection.platform != nil ? .headline.weight(.semibold).monospacedDigit() : .caption2
                ).foregroundStyle(connection.platform != nil ? .primary : .tertiary)
            }.frame(width: 58).debugLayoutBox(showLayoutDebug, color: .purple)
            Button {
                Haptics.selection()
                onTap()
            } label: {
                Image(systemName: "info.circle").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .padding(2).background(Color.accentColor.opacity(0.12), in: Circle()).contentShape(
                        Rectangle())
            }.buttonStyle(.borderless).debugLayoutBox(showLayoutDebug, color: .teal)
        }.padding(.horizontal, 16).padding(.vertical, 12).debugLayoutBox(showLayoutDebug, color: .yellow)
    }

    private var leaveTimeSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2), lineWidth: 4)
                Circle().trim(from: 0, to: progress).stroke(
                    urgencyColor, style: StrokeStyle(lineWidth: 4, lineCap: .round)
                ).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    if timeRemaining <= 0 {
                        Text("GO!").font(.system(.caption, design: .monospaced).weight(.bold))
                    } else if timeRemaining <= 60 {
                        // Under 1 minute: live countdown with seconds
                        Text(leaveTime, style: .timer).font(.system(.caption, design: .monospaced).weight(.bold))
                            .multilineTextAlignment(.center)
                    } else {
                        Text(formatCountdown(timeRemaining)).font(.system(.caption, design: .monospaced).weight(.bold))
                    }
                    if timeRemaining > 0, timeRemaining <= 60 {
                        Text("to go").font(.system(size: 8)).foregroundStyle(.secondary)
                    } else if timeRemaining > 60 {
                        Text("to leave").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
            }.frame(width: 56, height: 56).accessibilityLabel(countdownAccessibilityLabel).debugLayoutBox(
                showLayoutDebug,
                color: .orange
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Leave at").font(.caption).foregroundStyle(.secondary)
                Text(leaveTime, style: .time).font(.headline.monospacedDigit()).foregroundStyle(urgencyColor)
            }.debugLayoutBox(showLayoutDebug, color: .green)
            Spacer()

            // Pin button
            Button {
                Haptics.impact(.light)
                isPinned ? onUnpin() : onPin()
            } label: {
                Image(systemName: isPinned ? "pin.slash.fill" : "pin.fill").font(.caption.weight(.semibold))
                    .foregroundStyle(isPinned ? .white : .secondary).frame(width: 36, height: 36).background(
                        isPinned ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle()
                    )
            }.disabled(timeRemaining < 0 && !isPinned).accessibilityLabel(
                isPinned ? "Unpin journey" : "Pin as My Journey").debugLayoutBox(showLayoutDebug, color: .red)

            // Reminder button
            Button {
                Haptics.impact(.medium)
                isSelected ? onCancel() : onSchedule()
            } label: {
                Image(systemName: isSelected ? "bell.slash.fill" : "bell.fill").font(.body.weight(.semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44).background(
                        isSelected
                            ? Color.urgencyRedFallback(colorScheme)
                            : (timeRemaining < 0 ? .secondary : Color.accentColor), in: Circle()
                    )
            }.disabled(timeRemaining < 0 && !isSelected).accessibilityLabel(
                isSelected ? "Cancel reminder" : "Set reminder"
            ).accessibilityHint(
                isSelected ? "Removes the departure notification" : "Notifies you when it's time to leave")
                .debugLayoutBox(showLayoutDebug, color: .blue)
        }.padding(16).background(urgencyColor.opacity(colorScheme == .dark ? 0.15 : 0.08)).debugLayoutBox(
            showLayoutDebug,
            color: .mint
        )
    }

    private var countdownAccessibilityLabel: String {
        if timeRemaining <= 0 { return "Time to leave now" }
        let minutes = Int(timeRemaining) / 60
        let seconds = Int(timeRemaining) % 60
        if minutes >= 60 { return "\(minutes / 60) hours and \(minutes % 60) minutes to leave" }
        if minutes == 0 { return "\(seconds) seconds to leave" }
        return "\(minutes) minutes to leave"
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        // Round up to show remaining time (ceiling ensures user has enough time)
        let totalMinutes = Int(ceil(max(0, seconds) / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            if minutes == 0 { return "\(hours)h" }
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }
}

private extension View {
    @ViewBuilder
    func debugLayoutBox(_ enabled: Bool, color: Color) -> some View {
        if enabled {
            self
                .padding(2)
                .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.65), lineWidth: 1))
        } else {
            self
        }
    }
}

// MARK: - LineBadge

struct LineBadge: View {
    let line: String
    let colors: TrainLineColors?

    init(line: String, colors: TrainLineColors? = nil) {
        self.line = line
        self.colors = colors
    }

    var body: some View {
        let style = Color.lineBadgeStyle(for: line, apiColors: colors)
        return Text(line.uppercased())
            .font(.headline.weight(.bold))
            .foregroundStyle(style.foreground)
            .scalableText(minimumScale: 0.7)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(style.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if let border = style.border {
                    RoundedRectangle(cornerRadius: 8).stroke(border.opacity(0.7), lineWidth: 1)
                }
            }
    }
}

// MARK: - DelayBadge

struct DelayBadge: View {
    let minutes: Int
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.badge.exclamationmark")
            Text("+\(minutes)'")
        }.font(.caption.weight(.semibold)).foregroundStyle(.orange).padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.orange.opacity(colorScheme == .dark ? 0.25 : 0.15), in: Capsule())
    }
}

struct ServiceAlertBadge: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Alert")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.red.opacity(colorScheme == .dark ? 0.25 : 0.15), in: Capsule())
    }
}

// MARK: - PinBadge

struct PinBadge: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill").font(.system(size: 10))
            Text("MY JOURNEY").font(.system(size: 9, weight: .bold))
        }.foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3).background(
            Color.accentColor, in: Capsule()
        )
    }
}

#Preview("Connection Card") {
    let now = Date()
    let departure = now.addingTimeInterval(20 * 60)
    let arrival = departure.addingTimeInterval(34 * 60)

    let from = Station(
        id: "wien-meidling",
        name: "Wien Meidling",
        coordinate: nil,
        transportTypes: [.trainCommute],
        lines: []
    )
    let to = Station(
        id: "wien-hbf",
        name: "Wien Hbf",
        coordinate: nil,
        transportTypes: [.trainCommute],
        lines: []
    )

    let leg = ConnectionLeg(
        from: from,
        to: to,
        departureTime: departure,
        arrivalTime: arrival,
        platform: "5",
        lineNumber: "RJX 160",
        trainType: TrainType(id: "RJX", shortName: "RJX", displayName: "Railjet Xpress"),
        lineColors: TrainLineColors(backgroundHex: "#D71920", foregroundHex: "#FFFFFF"),
        isWalking: false,
        duration: arrival.timeIntervalSince(departure),
        finalDestination: to.name,
        stopCount: 4
    )

    let connection = TrainConnection(
        id: "preview-connection-card",
        lineNumber: "RJX 160",
        trainType: TrainType(id: "RJX", shortName: "RJX", displayName: "Railjet Xpress"),
        lineColors: TrainLineColors(backgroundHex: "#D71920", foregroundHex: "#FFFFFF"),
        departureTime: departure,
        arrivalTime: arrival,
        departureStation: from,
        arrivalStation: to,
        platform: "11A-B",
        delay: 10,
        status: .delayed,
        transfers: 1,
        legs: [leg],
        serviceAlerts: [
            ServiceAlert(
                id: "preview-alert",
                title: "Platform change",
                message: "Platform changed due to operations.",
                startsAt: nil,
                endsAt: nil,
                priority: 1,
                isActive: true
            ),
        ]
    )

    let displayConnection = DisplayConnection(
        connection: connection,
        leaveTime: departure.addingTimeInterval(-9 * 60),
        isSelected: true,
        isPinned: false,
        currentTime: now
    )

    ScrollView {
        ConnectionCard(
            displayConnection: displayConnection,
            onSchedule: {},
            onCancel: {},
            onPin: {},
            onUnpin: {},
            onTap: {},
            showLayoutDebug: true
        )
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
