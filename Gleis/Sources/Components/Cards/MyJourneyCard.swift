import SwiftUI

// MARK: - MyJourneyCard

struct MyJourneyCard: View {
    let journey: PinnedJourney
    let onUnpin: () -> Void
    var leaveTime: Date? = nil

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    private func isInProgress(at now: Date) -> Bool { now >= journey.departureTime && now < journey.arrivalTime }
    private func hasDeparted(at now: Date) -> Bool { now >= journey.departureTime }

    private func journeyProgress(at now: Date) -> Double {
        let total = journey.arrivalTime.timeIntervalSince(journey.departureTime)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(journey.departureTime) / total))
    }

    private func statusText(at now: Date) -> String {
        if isInProgress(at: now) { "In progress" } else if hasDeparted(at: now) { "Arrived" } else { "Upcoming" }
    }

    private func statusColor(at now: Date) -> Color {
        if isInProgress(at: now) { .green } else if hasDeparted(at: now) { .secondary } else { .blue }
    }

    private var displayLegs: [ConnectionLeg] {
        journey.legs.isEmpty ? [createFallbackLeg()] : journey.legs
    }

    private func headerDisplayLeg(at now: Date) -> ConnectionLeg? {
        let legs = travelLegs
        guard !legs.isEmpty else { return nil }

        if let activeLeg = legs.last(where: { leg in
            guard let departure = leg.departureTime else { return false }
            let arrival = leg.arrivalTime ?? .distantFuture
            return departure <= now && now < arrival
        }) {
            return activeLeg
        }

        if let mostRecentDepartedLeg = legs.last(where: { leg in
            guard let departure = leg.departureTime else { return false }
            return departure <= now
        }) {
            return mostRecentDepartedLeg
        }

        return legs.first
    }

    private func displayLineNumber(for headerLeg: ConnectionLeg?) -> String {
        if let legLine = headerLeg?.lineNumber.trimmingCharacters(in: .whitespacesAndNewlines),
           !legLine.isEmpty
        {
            return legLine
        }
        let journeyLine = journey.lineNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !journeyLine.isEmpty { return journeyLine }
        return "Train"
    }

    private func displayLineColors(for headerLeg: ConnectionLeg?) -> TrainLineColors? {
        headerLeg?.lineColors ?? journey.lineColors
    }

    private var travelLegs: [ConnectionLeg] {
        let legs = displayLegs
        let transitLegs = legs.filter { !$0.isWalking }
        return transitLegs.isEmpty ? legs : transitLegs
    }

    private var firstTravelLeg: ConnectionLeg? { travelLegs.first }
    private var lastTravelLeg: ConnectionLeg? { travelLegs.last }

    private var departurePlatformLabel: String? {
        firstTravelLeg?.platform.trimmedNonEmpty ?? journey.platform.trimmedNonEmpty
    }

    private var finalArrivalPlatformLabel: String? {
        lastTravelLeg?.arrivalPlatform.trimmedNonEmpty
    }

    private var routeRevealTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    var body: some View {
        // Stop, status and progress times are whole minutes, so the card redraws once a minute; only the leave countdown ticks every second.
        TimelineView(.everyMinute) { context in
            card(at: context.date)
        }
    }

    private func card(at now: Date) -> some View {
        VStack(spacing: 0) {
            headerSection(at: now)
                .background(Color.cardSurface(colorScheme))
                .zIndex(1)
            if isExpanded {
                VStack(spacing: 0) {
                    Divider().background(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
                        .padding(.horizontal, 16)
                    timelineSection(at: now)
                }
                .transition(routeRevealTransition)
            }
        }
        .background(Color.cardSurface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.5), lineWidth: 2))
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.08), radius: 12, y: 6)
    }

    private func headerSection(at now: Date) -> some View {
        VStack(spacing: 12) {
            titleRow(at: now)
            timingSection(at: now)
            routeToggleButton
        }.padding(16)
    }

    @ViewBuilder
    private func titleRow(at now: Date) -> some View {
        let headerLeg = headerDisplayLeg(at: now)
        let badge = LineBadge(line: displayLineNumber(for: headerLeg), colors: displayLineColors(for: headerLeg))
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    badge
                    Spacer(minLength: 8)
                    unpinButton
                }
                titleText(at: now)
            }
        } else {
            HStack(spacing: 12) {
                badge
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                titleText(at: now).layoutPriority(1)
                unpinButton
            }
        }
    }

    private func titleText(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    myJourneyPill
                    statusLabel(at: now)
                }
                VStack(alignment: .leading, spacing: 4) {
                    myJourneyPill
                    statusLabel(at: now)
                }
            }

            Text("\(journey.departureStation.name) → \(journey.arrivalStation.name)")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var myJourneyPill: some View {
        Text("My Journey")
            .textCase(.uppercase)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor, in: Capsule())
    }

    private func statusLabel(at now: Date) -> some View {
        Text(statusText(at: now))
            .font(.caption2.weight(.medium))
            .foregroundStyle(statusColor(at: now))
    }

    private var unpinButton: some View {
        Button {
            Haptics.impact(.light)
            onUnpin()
        } label: {
            Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
        }
        .accessibilityLabel("Unpin")
    }

    private func timingSection(at now: Date) -> some View {
        VStack(spacing: 8) {
            if isInProgress(at: now) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor).frame(
                            width: geo.size.width * journeyProgress(at: now))
                    }
                }.frame(height: 6)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    departureColumn(alignment: .leading)
                    Spacer(minLength: 16)
                    arrivalColumn(alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 8) {
                    departureColumn(alignment: .leading)
                    arrivalColumn(alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusPills(at: now)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    statusPills(at: now)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func departureColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("Departs").font(.caption2).foregroundStyle(.secondary)
            DelayedTimeText(time: journey.departureTime, delayMinutes: journey.delay)
            if let departurePlatformLabel {
                Text("Platform \(departurePlatformLabel)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func arrivalColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("Arrives").font(.caption2).foregroundStyle(.secondary)
            DelayedTimeText(time: journey.arrivalTime, delayMinutes: journey.delay, weight: .bold)
            if let finalArrivalPlatformLabel {
                Text("Platform \(finalArrivalPlatformLabel)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusPills(at now: Date) -> some View {
        if let leaveTime, !hasDeparted(at: now) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                    Text("Leave \(leaveTime, style: .time)")
                    LeaveCountdownText(leaveTime: leaveTime)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "figure.walk")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Leave \(leaveTime, style: .time)")
                        LeaveCountdownText(leaveTime: leaveTime)
                    }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color.blue.opacity(colorScheme == .dark ? 0.22 : 0.12),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }

        if journey.delay > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark")
                Text("+\(journey.delay) min")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(journey.delay == 1 ? "Delayed 1 minute" : "Delayed \(journey.delay) minutes")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.12),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }

    private var routeToggleButton: some View {
        Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .gleisToggle) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "Hide route" : "Show route").font(.caption.weight(.medium))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption)
            }.foregroundStyle(.secondary)
        }
    }

    private func timelineSection(at now: Date) -> some View {
        VStack(spacing: 0) {
            let legs = displayLegs

            ForEach(Array(legs.enumerated()), id: \.element.id) { legIndex, leg in
                JourneyLegSection(
                    leg: leg, isFirstLeg: legIndex == 0, isLastLeg: legIndex == legs.count - 1,
                    departureStation: leg.isWalking
                        ? nil : (legIndex == 0 ? journey.departureStation : leg.from),
                    arrivalStation: leg.isWalking
                        ? nil : (legIndex == legs.count - 1 ? journey.arrivalStation : leg.to),
                    arrivalPlatformOverride: legIndex == legs.count - 1 ? finalArrivalPlatformLabel : nil,
                    now: now
                )

                // Show transfer indicator between legs
                if legIndex < legs.count - 1, !(leg.isWalking && legIndex > 0) {
                    if let transition = ConnectionTransferPlanner.context(after: legIndex, legs: legs) {
                        let transferMinutes = ConnectionTransferPlanner.transferMinutes(
                            from: leg,
                            to: transition.targetLeg
                        )
                        TransferRow(
                            stationName: leg.to.name,
                            transferMinutes: transferMinutes,
                            nextLineNumber: transition.targetLeg.lineNumber,
                            currentPlatform: leg.arrivalPlatform ?? leg.platform,
                            nextPlatform: transition.targetLeg.platform,
                            nextDepartureTime: transition.targetLeg.departureTime,
                            lineColor: transition.targetLeg.displayLineColor,
                            isPassed: leg.arrivalTime.map { now >= $0 } ?? false,
                            involvesWalking: transition.involvesWalking,
                            nextLegIsWalking: transition.nextLegIsWalking,
                            hasUpcomingTransitLeg: transition.hasUpcomingTransitLeg
                        )
                    }
                }
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }

    private func createFallbackLeg() -> ConnectionLeg {
        ConnectionLeg(
            from: journey.departureStation, to: journey.arrivalStation, departureTime: journey.departureTime,
            arrivalTime: journey.arrivalTime, platform: journey.platform, lineNumber: journey.lineNumber,
            lineColors: journey.lineColors, isWalking: false,
            duration: journey.arrivalTime.timeIntervalSince(journey.departureTime)
        )
    }
}

// MARK: - LeaveCountdownText

private struct LeaveCountdownText: View {
    let leaveTime: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static func minutesUntilLeave(_ leaveTime: Date, now: Date) -> Int {
        let seconds = leaveTime.timeIntervalSince(now)
        return seconds <= 0 ? 0 : Int(ceil(seconds / 60))
    }

    private static func countdownLabel(minutes: Int) -> String {
        switch minutes {
        case 0: "now"
        case 1: "in 1 min"
        default: "in \(minutes) min"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let minutes = Self.minutesUntilLeave(leaveTime, now: context.date)
            Text(Self.countdownLabel(minutes: minutes))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                .animation(reduceMotion ? nil : .default, value: minutes)
        }
    }
}

// MARK: - JourneyLegSection

private struct JourneyLegSection: View {
    let leg: ConnectionLeg
    let isFirstLeg: Bool
    let isLastLeg: Bool
    let departureStation: Station?
    let arrivalStation: Station?
    let arrivalPlatformOverride: String?
    let now: Date

    private static let maxVisibleUpcomingStops = 3

    private var legLineColor: Color { leg.displayLineColor }

    private func intermediateStopsLayout() -> (visible: [IntermediateStop], hiddenUpcomingCount: Int) {
        if leg.arrivalTime.map({ now >= $0 }) ?? false { return ([], 0) }
        guard leg.departureTime.map({ now >= $0 }) ?? false else { return (leg.intermediateStops, 0) }

        var passed: [IntermediateStop] = []
        var upcoming: [IntermediateStop] = []
        for stop in leg.intermediateStops {
            if stop.arrivalTime.map({ now >= $0 }) ?? false { passed.append(stop) } else { upcoming.append(stop) }
        }
        let shownUpcoming = upcoming.prefix(Self.maxVisibleUpcomingStops)
        return (passed + shownUpcoming, upcoming.count - shownUpcoming.count)
    }

    private static func moreStopsText(count: Int) -> String {
        count == 1 ? "1 more stop" : "\(count) more stops"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Show departure endpoint for each transit leg.
            if departureStation != nil {
                JourneyStopRow(
                    name: departureStation?.name ?? leg.from.name,
                    time: ConnectionTransferPlanner.plannedTime(
                        from: leg.departureTime,
                        delayMinutes: leg.departureDelayMinutes ?? leg.delayMinutes
                    ),
                    platform: leg.platform,
                    delay: leg.departureDelayMinutes ?? leg.delayMinutes,
                    lineNumber: leg.lineNumber,
                    lineColors: leg.lineColors,
                    isEndpoint: true,
                    isPassed: leg.departureTime.map { now >= $0 } ?? false, showTopConnector: false,
                    showBottomConnector: true, lineColor: legLineColor, isTransferBoundary: !isFirstLeg
                )
            }

            // Intermediate stops
            if !leg.isWalking {
                let stopsLayout = intermediateStopsLayout()
                ForEach(stopsLayout.visible) { stop in
                    let stopTime = stop.arrivalTime ?? stop.departureTime
                    let stopDelay = stop.arrivalTime != nil ? stop.arrivalDelay : stop.departureDelay
                    JourneyStopRow(
                        name: stop.name,
                        time: ConnectionTransferPlanner.plannedTime(from: stopTime, delayMinutes: stopDelay),
                        platform: nil,
                        delay: stopDelay,
                        lineNumber: nil, lineColors: nil, isEndpoint: false,
                        isPassed: (stop.arrivalTime ?? stop.departureTime).map { now >= $0 } ?? false,
                        showTopConnector: true,
                        showBottomConnector: true, lineColor: legLineColor
                    )
                }

                if stopsLayout.hiddenUpcomingCount > 0 {
                    JourneyCollapsedStopsRow(
                        text: Self.moreStopsText(count: stopsLayout.hiddenUpcomingCount),
                        systemImage: "ellipsis.circle",
                        lineColor: legLineColor
                    )
                }
            }

            // Show arrival endpoint for each transit leg.
            if arrivalStation != nil {
                JourneyStopRow(
                    name: arrivalStation?.name ?? leg.to.name,
                    time: ConnectionTransferPlanner.plannedTime(
                        from: leg.arrivalTime,
                        delayMinutes: leg.arrivalDelayMinutes ?? leg.delayMinutes
                    ),
                    platform: arrivalPlatformOverride ?? leg.arrivalPlatform,
                    delay: leg.arrivalDelayMinutes ?? leg.delayMinutes,
                    lineNumber: nil, lineColors: nil, isEndpoint: true,
                    isPassed: leg.arrivalTime.map { now >= $0 } ?? false, showTopConnector: true,
                    showBottomConnector: false, lineColor: legLineColor, isTransferBoundary: !isLastLeg
                )
            }
        }
    }
}

// MARK: - TimelineConnector

/// A rail segment that keeps its design height but stretches when wrapped text makes the row taller.
private struct TimelineConnector: View {
    let color: Color
    let minimumHeight: CGFloat

    var body: some View {
        Rectangle().fill(color)
            .frame(width: 2)
            .frame(minHeight: minimumHeight, idealHeight: minimumHeight, maxHeight: .infinity)
    }
}

// MARK: - JourneyCollapsedStopsRow

private struct JourneyCollapsedStopsRow: View {
    let text: String
    let systemImage: String
    let lineColor: Color

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                TimelineConnector(color: lineColor.opacity(0.25), minimumHeight: 8)
                Circle().fill(
                    colorScheme == .dark ? lineColor.opacity(0.3) : lineColor.opacity(0.16)
                ).frame(width: 6, height: 6)
                TimelineConnector(color: lineColor.opacity(0.25), minimumHeight: 8)
            }.frame(width: 20)

            Label(text, systemImage: systemImage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        // Lets the rail stretch to the wrapped label's height.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 1)
    }
}

// MARK: - JourneyStopRow

private struct JourneyStopRow: View {
    let name: String
    let time: Date?
    let platform: String?
    let delay: Int?
    let lineNumber: String?
    let lineColors: TrainLineColors?
    let isEndpoint: Bool
    let isPassed: Bool
    let showTopConnector: Bool
    let showBottomConnector: Bool
    let lineColor: Color
    var isTransferBoundary: Bool = false

    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .caption) private var minimumInlineStationNameWidth: CGFloat = 80

    private var endpointConnectorHeight: CGFloat { isTransferBoundary ? 6 : 8 }
    private var endpointNodeDiameter: CGFloat { isTransferBoundary ? 10 : 12 }
    private var endpointNodeStroke: CGFloat { isTransferBoundary ? 1.5 : 2 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            timelineIndicator

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    lineBadge
                    stopNameAndTime
                    Spacer(minLength: 8)
                    platformLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    lineBadge
                    stopNameAndTime
                    platformLabel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Lets the rail stretch to the wrapped station name's height.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, isEndpoint ? 4 : 1)
    }

    private var timelineIndicator: some View {
        let connectorColor = isPassed ? lineColor : lineColor.opacity(0.35)
        let nodeFillColor =
            isPassed ? lineColor : (colorScheme == .dark ? lineColor.opacity(0.38) : lineColor.opacity(0.22))
        let connectorHeight: CGFloat = isEndpoint ? endpointConnectorHeight : 10
        let nodeDiameter: CGFloat = isEndpoint ? endpointNodeDiameter : 6

        return VStack(spacing: 0) {
            TimelineConnector(color: showTopConnector ? connectorColor : .clear, minimumHeight: connectorHeight)
            Circle().fill(nodeFillColor)
                .frame(width: nodeDiameter, height: nodeDiameter)
                .overlay(Circle().stroke(lineColor, lineWidth: isEndpoint ? endpointNodeStroke : 1))
            TimelineConnector(color: showBottomConnector ? connectorColor : .clear, minimumHeight: connectorHeight)
        }.frame(width: 20)
    }

    @ViewBuilder
    private var lineBadge: some View {
        if let lineNumber, isEndpoint {
            let style = Color.lineBadgeStyle(for: lineNumber, apiColors: lineColors)
            Text(lineNumber)
                .font(.caption2.weight(.bold))
                .foregroundStyle(style.foreground)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(style.background, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var stationName: Text {
        let weight: Font.Weight = isEndpoint ? .semibold : .regular
        guard isTransferBoundary else { return Text(name).fontWeight(weight) }
        let transferGlyph = Text(Image(systemName: "arrow.triangle.branch"))
            .font(.caption2.weight(.semibold))
            .foregroundColor(.orange)
        return Text("\(Text(name).fontWeight(weight)) \(transferGlyph)")
    }

    private var stopNameAndTime: some View {
        VStack(alignment: .leading, spacing: 1) {
            stationName
                .font(.caption)
                .foregroundStyle(isPassed ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                // Ideal width only, so a long name wraps inline instead of forcing the stacked row.
                .frame(idealWidth: minimumInlineStationNameWidth, alignment: .leading)

            if let time {
                HStack(spacing: 4) {
                    Text(time, style: .time).font(
                        isEndpoint ? .caption.monospacedDigit().weight(.medium) : .caption2.monospacedDigit()
                    ).foregroundStyle(isPassed ? .secondary : .primary)

                    if let delay, delay > 0 {
                        Text("+\(delay) min").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                    }
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var platformLabel: some View {
        if let platform, isEndpoint {
            Text("Platform \(platform)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
        }
    }
}

#Preview("Single Leg Journey") {
    ScrollView {
        MyJourneyCard(
            journey: PinnedJourney(
                connectionId: "test", lineNumber: "S1", departureTime: Date().addingTimeInterval(-1800),
                arrivalTime: Date().addingTimeInterval(3600),
                departureStation: Station(
                    id: "1", name: "Maribor", coordinate: nil, lines: []
                ),
                arrivalStation: Station(
                    id: "2", name: "Graz Hbf", coordinate: nil, lines: []
                ),
                platform: "3", delay: 5, pinnedAt: Date(),
                legs: [
                    ConnectionLeg(
                        from: Station(
                            id: "1", name: "Maribor", coordinate: nil, lines: []
                        ),
                        to: Station(
                            id: "2", name: "Graz Hbf", coordinate: nil, lines: []
                        ),
                        departureTime: Date().addingTimeInterval(-1800), arrivalTime: Date().addingTimeInterval(3600),
                        platform: "3", lineNumber: "S1", isWalking: false, duration: 5400,
                        intermediateStops: [
                            IntermediateStop(
                                id: "s1", name: "Pesnica", arrivalTime: Date().addingTimeInterval(-1200),
                                departureTime: nil, arrivalDelay: 2, departureDelay: nil, platform: "1"
                            ),
                            IntermediateStop(
                                id: "s2", name: "Šentilj", arrivalTime: Date().addingTimeInterval(-600),
                                departureTime: nil, arrivalDelay: nil, departureDelay: nil, platform: "1"
                            ),
                            IntermediateStop(
                                id: "s3", name: "Spielfeld-Straß", arrivalTime: Date().addingTimeInterval(600),
                                departureTime: nil, arrivalDelay: nil, departureDelay: nil, platform: nil
                            ),
                            IntermediateStop(
                                id: "s4", name: "Leibnitz", arrivalTime: Date().addingTimeInterval(1800),
                                departureTime: nil, arrivalDelay: nil, departureDelay: nil, platform: "2"
                            ),
                        ]
                    ),
                ], transfers: 0
            )
        ) {}.padding()
    }.background(Color(.systemGroupedBackground))
}

#Preview("Journey with Transfer") {
    ScrollView {
        MyJourneyCard(
            journey: PinnedJourney(
                connectionId: "test-transfer", lineNumber: "S1", departureTime: Date().addingTimeInterval(-1800),
                arrivalTime: Date().addingTimeInterval(7200),
                departureStation: Station(
                    id: "1", name: "Maribor", coordinate: nil, lines: []
                ),
                arrivalStation: Station(
                    id: "3", name: "Wien Hbf", coordinate: nil, lines: []
                ),
                platform: "3", delay: 0, pinnedAt: Date(),
                legs: [
                    ConnectionLeg(
                        from: Station(
                            id: "1", name: "Maribor", coordinate: nil, lines: []
                        ),
                        to: Station(
                            id: "2", name: "Graz Hbf", coordinate: nil, lines: []
                        ),
                        departureTime: Date().addingTimeInterval(-1800), arrivalTime: Date().addingTimeInterval(1800),
                        platform: "3", lineNumber: "S1", isWalking: false, duration: 3600,
                        intermediateStops: [
                            IntermediateStop(
                                id: "s1", name: "Šentilj", arrivalTime: Date().addingTimeInterval(-600),
                                departureTime: nil, arrivalDelay: nil, departureDelay: nil, platform: "1"
                            ),
                            IntermediateStop(
                                id: "s2", name: "Spielfeld-Straß", arrivalTime: Date().addingTimeInterval(600),
                                departureTime: nil, arrivalDelay: nil, departureDelay: nil, platform: nil
                            ),
                        ]
                    ),
                    ConnectionLeg(
                        from: Station(
                            id: "2", name: "Graz Hbf", coordinate: nil, lines: []
                        ),
                        to: Station(
                            id: "3", name: "Wien Hbf", coordinate: nil, lines: []
                        ),
                        departureTime: Date().addingTimeInterval(2400), arrivalTime: Date().addingTimeInterval(7200),
                        platform: "5", lineNumber: "RJX 160", isWalking: false, duration: 4800,
                        intermediateStops: [
                            IntermediateStop(
                                id: "s3", name: "Bruck an der Mur", arrivalTime: Date().addingTimeInterval(3600),
                                departureTime: nil, arrivalDelay: nil, departureDelay: nil, platform: "2"
                            ),
                            IntermediateStop(
                                id: "s4", name: "Mürzzuschlag", arrivalTime: Date().addingTimeInterval(4800),
                                departureTime: nil, arrivalDelay: nil, departureDelay: nil, platform: "1"
                            ),
                            IntermediateStop(
                                id: "s5", name: "Wiener Neustadt", arrivalTime: Date().addingTimeInterval(6000),
                                departureTime: nil, arrivalDelay: nil, departureDelay: nil, platform: "3"
                            ),
                        ]
                    ),
                ], transfers: 1
            )
        ) {}.padding()
    }.background(Color(.systemGroupedBackground))
}

#Preview("Tight Transfer Warning") {
    ScrollView {
        MyJourneyCard(
            journey: PinnedJourney(
                connectionId: "test-tight", lineNumber: "IC 515", departureTime: Date().addingTimeInterval(600),
                arrivalTime: Date().addingTimeInterval(7200),
                departureStation: Station(
                    id: "1", name: "Ljubljana", coordinate: nil, lines: []
                ),
                arrivalStation: Station(
                    id: "3", name: "München Hbf", coordinate: nil, lines: []
                ),
                platform: "1", delay: 0, pinnedAt: Date(),
                legs: [
                    ConnectionLeg(
                        from: Station(
                            id: "1", name: "Ljubljana", coordinate: nil, lines: []
                        ),
                        to: Station(
                            id: "2", name: "Villach Hbf", coordinate: nil, lines: []
                        ),
                        departureTime: Date().addingTimeInterval(600), arrivalTime: Date().addingTimeInterval(3000),
                        platform: "1", lineNumber: "IC 515", isWalking: false, duration: 2400, intermediateStops: []
                    ),
                    ConnectionLeg(
                        from: Station(
                            id: "2", name: "Villach Hbf", coordinate: nil, lines: []
                        ),
                        to: Station(
                            id: "3", name: "München Hbf", coordinate: nil, lines: []
                        ),
                        departureTime: Date().addingTimeInterval(3180), // Only 3 minutes transfer!
                        arrivalTime: Date().addingTimeInterval(7200), platform: "4", lineNumber: "EC 112",
                        isWalking: false, duration: 4020, intermediateStops: []
                    ),
                ], transfers: 1
            )
        ) {}.padding()
    }.background(Color(.systemGroupedBackground))
}

#Preview("My Journey Header Compact") {
    ScrollView {
        MyJourneyCard(
            journey: PinnedJourney(
                connectionId: "compact-header",
                lineNumber: "RJX 134",
                departureTime: Date().addingTimeInterval(4 * 60),
                arrivalTime: Date().addingTimeInterval(2 * 60 * 60 + 41 * 60),
                departureStation: Station(
                    id: "graz",
                    name: "Graz",
                    coordinate: nil,
                    lines: []
                ),
                arrivalStation: Station(
                    id: "stadlau",
                    name: "Stadlau (Wien)",
                    coordinate: nil,
                    lines: []
                ),
                platform: "3",
                delay: 1,
                pinnedAt: Date(),
                legs: [
                    ConnectionLeg(
                        from: Station(id: "graz", name: "Graz", coordinate: nil, lines: []),
                        to: Station(
                            id: "stadlau",
                            name: "Stadlau (Wien)",
                            coordinate: nil,
                            lines: []
                        ),
                        departureTime: Date().addingTimeInterval(4 * 60),
                        arrivalTime: Date().addingTimeInterval(2 * 60 * 60 + 41 * 60),
                        platform: "3",
                        lineNumber: "RJX 134",
                        isWalking: false,
                        duration: 2 * 60 * 60 + 37 * 60
                    ),
                ],
                transfers: 1
            ),
            onUnpin: {}
        )
        .padding()
    }
    .background(Color(.systemGroupedBackground))
    .frame(width: 380)
}
