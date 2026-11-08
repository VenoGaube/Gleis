import SwiftUI

// MARK: - ConnectionCard

struct ConnectionCard: View {
    let displayConnection: DisplayConnection
    let onSchedule: () -> Void
    let onCancel: () -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void
    let onTap: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var ringDiameter: CGFloat = 56
    @ScaledMetric(relativeTo: .caption2) private var ringCaptionSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var pinButtonDiameter: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var reminderButtonDiameter: CGFloat = 44
    @State private var isExpanded = false

    // Convenience accessors
    private var connection: TrainConnection { displayConnection.connection }
    private var leaveTime: Date { displayConnection.leaveTime }
    private var isLeaveWindowPassed: Bool { displayConnection.isLeaveWindowPassed }
    private var hasDeparted: Bool { displayConnection.hasDeparted }
    private var isLeaveTimePast: Bool { isLeaveWindowPassed || hasDeparted }
    private var isSelected: Bool { displayConnection.isSelected }
    private var isPinned: Bool { displayConnection.isPinned }
    private var isShowingMissedSummary: Bool { isLeaveWindowPassed && !isExpanded }
    private var scheduledDepartureTime: Date? {
        scheduledTimeIfDelayed(from: connection.departureTime, delayMinutes: connection.delay)
    }
    private var scheduledArrivalTime: Date? {
        scheduledTimeIfDelayed(from: connection.arrivalTime, delayMinutes: connection.delay)
    }

    var body: some View {
        Button(action: openDetailsOrToggleExpansion) {
            cardContent
                .foregroundStyle(.primary)
                .background(cardBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
                .overlay(cardBorder)
                .shadow(color: shadowColor, radius: 8, y: 4)
                .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
        }
        .buttonStyle(ConnectionCardPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardSpokenSummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(cardAccessibilityHint)
        .accessibilityAction(.default) { openDetailsOrToggleExpansion() }
        .accessibilityActions {
            if isLeaveWindowPassed {
                Button("Connection Details") { onTap() }
            }
            if !isLeaveTimePast || isSelected {
                Button(isSelected ? "Cancel Reminder" : "Remind Me") { isSelected ? onCancel() : onSchedule() }
            }
            if !hasDeparted || isPinned {
                Button(isPinned ? "Unpin" : "Pin") { isPinned ? onUnpin() : onPin() }
            }
        }
    }

    private func openDetailsOrToggleExpansion() {
        guard isLeaveWindowPassed else { return onTap() }
        withAnimation(reduceMotion ? nil : .gleisToggle) { isExpanded.toggle() }
    }

    private var cardAccessibilityHint: String {
        guard isLeaveWindowPassed else { return "Opens connection details" }
        return isExpanded ? "Collapses the card" : "Shows the full connection"
    }

    private var cardSpokenSummary: String {
        var parts = displayConnection.spokenTimetable
        parts.append(connection.transferSummary)
        parts.append(tripFactsLine)
        if isLeaveTimePast { parts.append("leave time passed") }
        if isSelected { parts.append("reminder set") }
        if isPinned { parts.append("pinned as My Journey") }
        return parts.joined(separator: ", ")
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            if isShowingMissedSummary {
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
        Color.cardSurface(colorScheme)
    }

    private var cardCornerRadius: CGFloat {
        isShowingMissedSummary ? 12 : 16
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

    // MARK: Missed summary

    // Below the accessibility sizes the row stays one line and a long station name wraps inside it.
    private var compactMissedView: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    LineBadge(line: connection.lineNumber, colors: connection.lineColors)
                    missedDetails
                    missedExpandHint
                }
            } else {
                HStack(spacing: 12) {
                    LineBadge(line: connection.lineNumber, colors: connection.lineColors)
                    missedDetails
                    Spacer()
                    missedExpandHint
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).opacity(0.6)
    }

    private var missedDetails: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(connection.arrivalStation.name).font(.subheadline.weight(.medium))
            Text(connection.departureTime, style: .time).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var missedExpandHint: some View {
        HStack(spacing: 12) {
            Text("Leave now").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    LineBadge(line: connection.lineNumber, colors: connection.lineColors)
                    headerStatusBadges(alignment: .leading)
                    routeStations
                }
            } else {
                HStack(spacing: 12) {
                    LineBadge(line: connection.lineNumber, colors: connection.lineColors)
                    routeStations
                    Spacer()
                    headerStatusBadges(alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private var routeStations: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.departureStation.name).font(.subheadline.weight(.medium))
                    if isPinned { PinBadge() }
                }
            } else {
                HStack(spacing: 6) {
                    Text(connection.departureStation.name).font(.subheadline.weight(.medium))
                    if isPinned { PinBadge().fixedSize() }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.caption2)
                Text(connection.arrivalStation.name).font(.caption)
            }.foregroundStyle(.secondary)
        }
    }

    // A single badge sits centred in a 40 pt band so the header keeps its height whatever the status.
    private func headerStatusBadges(alignment: HorizontalAlignment) -> some View {
        ConnectionStatusBadges(connection: connection, alignment: alignment)
            .frame(minHeight: 40, alignment: .center)
    }

    // MARK: Times, trip facts and platform

    // No column has a minimum width, so the one-row layout wins whenever its text fits on one line.
    private var timeInfoSection: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedTimesAndPlatform
            } else {
                ViewThatFits(in: .horizontal) {
                    oneRowTimesAndPlatform
                    twoRowTimesAndPlatform
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var oneRowTimesAndPlatform: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                timeColumn("Departs", time: connection.departureTime, scheduledTime: scheduledDepartureTime)
                    .layoutPriority(2)
                tripFactsColumn.frame(maxWidth: .infinity)
                timeColumn("Arrives", time: connection.arrivalTime, scheduledTime: scheduledArrivalTime)
                    .layoutPriority(2)
            }.frame(maxWidth: .infinity)
            Divider().frame(height: 40).padding(2)
            platformColumn(alignment: .center)
            connectionDetailsButton
        }
    }

    private var twoRowTimesAndPlatform: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                timeColumn("Departs", time: connection.departureTime, scheduledTime: scheduledDepartureTime)
                tripFactsColumn.frame(maxWidth: .infinity)
                timeColumn("Arrives", time: connection.arrivalTime, scheduledTime: scheduledArrivalTime)
            }
            HStack(spacing: 8) {
                platformColumn(alignment: .leading)
                Spacer(minLength: 8)
                connectionDetailsButton
            }
        }
    }

    private var stackedTimesAndPlatform: some View {
        VStack(alignment: .leading, spacing: 10) {
            timeColumn(
                "Departs", time: connection.departureTime, scheduledTime: scheduledDepartureTime,
                alignment: .leading)
            timeColumn(
                "Arrives", time: connection.arrivalTime, scheduledTime: scheduledArrivalTime, alignment: .leading)
            Text(tripFactsLine).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            transferChip
            HStack(spacing: 8) {
                platformColumn(alignment: .leading)
                Spacer(minLength: 8)
                connectionDetailsButton
            }
        }
    }

    private func timeColumn(
        _ title: String, time: Date, scheduledTime: Date?, alignment: HorizontalAlignment = .center
    ) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title).textCase(.uppercase).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            if let scheduledTime {
                VStack(alignment: alignment, spacing: 2) {
                    Text(scheduledTime, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Text(time, style: .time)
                        .font(.headline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            } else {
                Text(time, style: .time).font(.headline.weight(.semibold).monospacedDigit())
            }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .center)
    }

    private var tripFactsColumn: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text(formattedTripDuration).font(.caption2).foregroundStyle(.secondary)
            if let stopsText {
                Text(stopsText).font(.caption2.weight(.semibold)).foregroundStyle(.blue)
            }
            transferChip
        }
        .multilineTextAlignment(.center)
    }

    private var transferChipColor: Color {
        if connection.transfers == 0 { return .green }
        return connection.transfers >= 2 ? .red : .orange
    }

    private var transferChip: some View {
        HStack(spacing: 3) {
            if connection.transfers == 0 {
                Image(systemName: "checkmark.circle.fill")
                Text("Direct")
            } else {
                Text("\(connection.transfers)")
                Image(systemName: "arrow.triangle.branch")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(transferChipColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(transferChipColor.opacity(connection.transfers == 0 ? 0.12 : 0.15), in: Capsule())
    }

    private var formattedTripDuration: String {
        "\(Int(connection.duration / 60)) min"
    }

    private var stopsText: String? {
        guard let stops = connection.totalStopCount, stops > 0 else { return nil }
        return stops == 1 ? "1 stop" : "\(stops) stops"
    }

    private var tripFactsLine: String {
        [formattedTripDuration, stopsText].compactMap { $0 }.joined(separator: " · ")
    }

    private func platformColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("Platform").font(.caption2).foregroundStyle(.secondary)
            Text(connection.platform ?? "—")
                .font(connection.platform != nil ? .headline.weight(.semibold).monospacedDigit() : .caption2)
                .foregroundStyle(connection.platform != nil ? .primary : .tertiary)
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .center)
    }

    // The onTap closure owns the haptic, so the button does not add a second one.
    private var connectionDetailsButton: some View {
        Button(action: onTap) {
            Image(systemName: "info.circle").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                .padding(2).background(Color.accentColor.opacity(0.12), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Connection details")
    }

    // MARK: Leave time

    // Past the countdown window the ring ticks once a minute; inside it, every second.
    private var leaveTimeSection: some View {
        TimelineView(.everyMinute) { minuteContext in
            if displayConnection.timeRemaining(at: minuteContext.date) > DisplayConnection.leaveCountdownWindow {
                leaveTimeContent(now: minuteContext.date)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    leaveTimeContent(now: context.date)
                }
            }
        }
    }

    private func leaveTimeContent(now: Date) -> some View {
        let timeRemaining = displayConnection.timeRemaining(at: now)
        let urgencyColor = displayConnection.urgencyColor(at: now)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                leaveTimeSummary(now: now, urgencyColor: urgencyColor)
                Spacer()
                actionButtons(timeRemaining: timeRemaining)
            }
            VStack(alignment: .leading, spacing: 12) {
                leaveTimeSummary(now: now, urgencyColor: urgencyColor)
                actionButtons(timeRemaining: timeRemaining)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(urgencyColor.opacity(colorScheme == .dark ? 0.15 : 0.08))
    }

    private func leaveTimeSummary(now: Date, urgencyColor: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                countdownRing(now: now, urgencyColor: urgencyColor)
                leaveAtLabel(urgencyColor: urgencyColor)
            }
            VStack(alignment: .leading, spacing: 8) {
                countdownRing(now: now, urgencyColor: urgencyColor)
                leaveAtLabel(urgencyColor: urgencyColor)
            }
        }
    }

    private func leaveAtLabel(urgencyColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Leave at").font(.caption).foregroundStyle(.secondary)
            Text(leaveTime, style: .time).font(.headline.monospacedDigit()).foregroundStyle(urgencyColor)
        }
    }

    private func countdownRing(now: Date, urgencyColor: Color) -> some View {
        let timeRemaining = displayConnection.timeRemaining(at: now)
        let countdownText = formatCountdown(timeRemaining)
        return ZStack {
            Circle().stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2), lineWidth: 4)
            Circle().trim(from: 0, to: displayConnection.progress(at: now)).stroke(
                urgencyColor, style: StrokeStyle(lineWidth: 4, lineCap: .round)
            ).rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                if timeRemaining <= 0 {
                    Text("GO!").font(.system(.caption, design: .monospaced).weight(.bold))
                } else if timeRemaining <= 60 {
                    Text(leaveTime, style: .timer).font(.system(.caption, design: .monospaced).weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("to leave").font(.system(size: ringCaptionSize)).foregroundStyle(.secondary)
                } else {
                    Text(countdownText)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .default, value: countdownText)
                        .accessibilityLabel(spokenCountdown(timeRemaining))
                    Text("to leave").font(.system(size: ringCaptionSize)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }

    private func actionButtons(timeRemaining: TimeInterval) -> some View {
        HStack(spacing: 16) {
            Button {
                Haptics.impact(.light)
                isPinned ? onUnpin() : onPin()
            } label: {
                Image(systemName: isPinned ? "pin.slash.fill" : "pin.fill")
                    .font(.caption.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(reduceMotion ? nil : .default, value: isPinned)
                    .foregroundStyle(isPinned ? .white : .secondary)
                    .frame(width: pinButtonDiameter, height: pinButtonDiameter)
                    .background(isPinned ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
            }
            .buttonStyle(.borderless)
            .disabled(hasDeparted && !isPinned)

            Button {
                Haptics.impact(.medium)
                isSelected ? onCancel() : onSchedule()
            } label: {
                Image(systemName: isSelected ? "bell.slash.fill" : "bell.fill")
                    .font(.body.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(reduceMotion ? nil : .default, value: isSelected)
                    .foregroundStyle(.white)
                    .frame(width: reminderButtonDiameter, height: reminderButtonDiameter)
                    .background(
                        isSelected
                            ? Color.urgencyRedFallback(colorScheme)
                            : (timeRemaining < 0 ? .secondary : Color.accentColor), in: Circle()
                    )
            }
            .buttonStyle(.borderless)
            .disabled(timeRemaining < 0 && !isSelected)
        }
    }

    private func spokenCountdown(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(ceil(max(0, seconds) / 60))
        return Duration.seconds(totalMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        // Rounded up so the ring never shows less time than the user has.
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

// MARK: - ConnectionCardPressStyle

/// Shrinks the card while the finger is down, or dims it under Reduce Motion.
struct ConnectionCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}

// MARK: - Connection descriptions

private extension TrainConnection {
    /// "Direct", or the first change station with its change time, such as "via Linz Hbf (5 min change)".
    var transferSummary: String {
        guard transfers > 0 else { return "Direct" }
        let rideLegs = legs.filter { !$0.isWalking }
        guard rideLegs.count >= 2 else { return transfers == 1 ? "1 change" : "\(transfers) changes" }
        var summary = "via \(rideLegs[0].to.name)"
        if let arrival = rideLegs[0].arrivalTime, let departure = rideLegs[1].departureTime {
            summary += " (\(max(0, Int(departure.timeIntervalSince(arrival) / 60))) min change)"
        }
        let laterChanges = rideLegs.count - 2
        if laterChanges > 0 { summary += laterChanges == 1 ? " +1 more change" : " +\(laterChanges) more changes" }
        return summary
    }
}

private extension DisplayConnection {
    /// The card's spoken parts: line, status, leave, departure, arrival, platform.
    var spokenTimetable: [String] {
        func spoken(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        var parts = [connection.lineNumber]
        if connection.isCancelled { parts.append("cancelled") }
        parts.append("leave at \(spoken(leaveTime))")
        var departs = "departs \(spoken(connection.departureTime))"
        if let scheduled = scheduledTimeIfDelayed(from: connection.departureTime, delayMinutes: connection.delay) {
            let lateness = connection.delay == 1 ? "delayed 1 minute" : "delayed \(connection.delay) minutes"
            departs += ", \(lateness), scheduled \(spoken(scheduled))"
        }
        parts.append(departs)
        parts.append("arrives \(spoken(connection.arrivalTime))")
        if let platform = connection.platform { parts.append("platform \(platform)") }
        if connection.hasServiceAlerts { parts.append("service alert") }
        return parts
    }
}

// MARK: - ConnectionStatusBadges

/// Cancelled wins over everything; otherwise the alert and delay badges, stacked when both apply.
struct ConnectionStatusBadges: View {
    let connection: TrainConnection
    let alignment: HorizontalAlignment

    var body: some View {
        if connection.isCancelled {
            CancelledBadge()
        } else if connection.hasServiceAlerts, connection.isDelayed {
            VStack(alignment: alignment, spacing: 6) {
                ServiceAlertBadge()
                DelayBadge(minutes: connection.delay)
            }
        } else if connection.hasServiceAlerts {
            ServiceAlertBadge()
        } else if connection.isDelayed {
            DelayBadge(minutes: connection.delay)
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
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(style.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - DelayBadge

struct DelayBadge: View {
    let minutes: Int
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.badge.exclamationmark")
            Text("+\(minutes) min")
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .default, value: minutes)
        }.font(.caption.weight(.semibold)).foregroundStyle(.orange).padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.orange.opacity(colorScheme == .dark ? 0.25 : 0.15), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(minutes == 1 ? "Delayed 1 minute" : "Delayed \(minutes) minutes")
    }
}

struct CancelledBadge: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.octagon.fill")
            Text("Cancelled")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.red)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.red.opacity(colorScheme == .dark ? 0.3 : 0.18), in: Capsule())
        .accessibilityLabel("Cancelled")
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
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 9

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill").font(.system(size: iconSize))
            Text("My Journey").textCase(.uppercase).font(.system(size: labelSize, weight: .bold))
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
        lines: []
    )
    let to = Station(
        id: "wien-hbf",
        name: "Wien Hbf",
        coordinate: nil,
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
        VStack(spacing: 12) {
            ConnectionCard(
                displayConnection: displayConnection,
                onSchedule: {},
                onCancel: {},
                onPin: {},
                onUnpin: {},
                onTap: {}
            )
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
