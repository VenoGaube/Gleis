import SwiftUI

// MARK: - MyJourneyCard

struct MyJourneyCard: View {
    let journey: PinnedJourney
    let onUnpin: () -> Void
    let leaveTime: Date?
    let showLayoutDebug: Bool

    init(
        journey: PinnedJourney,
        onUnpin: @escaping () -> Void,
        leaveTime: Date? = nil,
        showLayoutDebug: Bool = false
    ) {
        self.journey = journey
        self.onUnpin = onUnpin
        self.leaveTime = leaveTime
        self.showLayoutDebug = showLayoutDebug
    }

    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = true

    private func normalizedPlatformValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private var journeyProgress: Double {
        let now = Date()
        let total = journey.arrivalTime.timeIntervalSince(journey.departureTime)
        let elapsed = now.timeIntervalSince(journey.departureTime)
        return min(1, max(0, elapsed / total))
    }

    private var statusText: String {
        if journey.isInProgress { "In Progress" } else if journey.hasDeparted { "Completed" } else { "Upcoming" }
    }

    private var statusColor: Color {
        if journey.isInProgress { .green } else if journey.hasDeparted { .secondary } else { .blue }
    }

    private var headerLegCandidates: [ConnectionLeg] {
        let sourceLegs = journey.legs.isEmpty ? [createFallbackLeg()] : journey.legs
        let transitLegs = sourceLegs.filter { !$0.isWalking }
        return transitLegs.isEmpty ? sourceLegs : transitLegs
    }

    private var headerDisplayLeg: ConnectionLeg? {
        let now = Date()
        let legs = headerLegCandidates
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

    private var displayLineNumber: String {
        if let legLine = headerDisplayLeg?.lineNumber.trimmingCharacters(in: .whitespacesAndNewlines),
           !legLine.isEmpty
        {
            return legLine
        }
        let journeyLine = journey.lineNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !journeyLine.isEmpty { return journeyLine }
        return "Train"
    }

    private var displayLineColors: TrainLineColors? {
        if let legColors = headerDisplayLeg?.lineColors { return legColors }
        return journey.lineColors
    }

    private var scheduledDeparture: Date? {
        guard journey.delay > 0 else { return nil }
        return journey.departureTime.addingTimeInterval(TimeInterval(-journey.delay * 60))
    }

    private var plannedArrival: Date? {
        guard journey.delay > 0 else { return nil }
        return journey.arrivalTime.addingTimeInterval(TimeInterval(-journey.delay * 60))
    }

    private var leaveCountdownText: String? {
        guard let leaveTime else { return nil }
        let seconds = leaveTime.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        let minutes = Int(ceil(seconds / 60))
        if minutes <= 1 { return "in <1 min" }
        return "in \(minutes) min"
    }

    private var travelLegs: [ConnectionLeg] {
        let legs = journey.legs.isEmpty ? [createFallbackLeg()] : journey.legs
        let transitLegs = legs.filter { !$0.isWalking }
        return transitLegs.isEmpty ? legs : transitLegs
    }

    private var firstTravelLeg: ConnectionLeg? { travelLegs.first }
    private var lastTravelLeg: ConnectionLeg? { travelLegs.last }

    private var departurePlatformLabel: String? {
        normalizedPlatformValue(firstTravelLeg?.platform) ?? normalizedPlatformValue(journey.platform)
    }

    private var finalArrivalPlatformLabel: String? {
        normalizedPlatformValue(lastTravelLeg?.arrivalPlatform)
    }

    @ViewBuilder
    private var departureTimeValue: some View {
        if let scheduledDeparture {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(scheduledDeparture, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .strikethrough()
                Text(journey.departureTime, style: .time)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        } else {
            Text(journey.departureTime, style: .time).font(.headline.monospacedDigit())
        }
    }

    @ViewBuilder
    private var arrivalTimeValue: some View {
        if let plannedArrival {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(plannedArrival, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .strikethrough()
                Text(journey.arrivalTime, style: .time)
                    .font(.headline.monospacedDigit())
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)
            }
        } else {
            Text(journey.arrivalTime, style: .time)
                .font(.headline.monospacedDigit())
                .fontWeight(.bold)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            if isExpanded {
                VStack(spacing: 0) {
                    Divider().background(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
                        .padding(.horizontal, 16)
                    timelineSection
                }
                .clipped()
                .transition(
                    .asymmetric(insertion: .topDownReveal, removal: .opacity)
                )
            }
        }.background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground)).clipShape(
            RoundedRectangle(cornerRadius: 16)
        ).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.5), lineWidth: 2)).shadow(
            color: colorScheme == .dark ? .clear : .black.opacity(0.08), radius: 12, y: 6
        )
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                LineBadge(line: displayLineNumber, colors: displayLineColors)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .debugJourneyLayoutBox(showLayoutDebug, color: .indigo)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("MY JOURNEY")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor, in: Capsule())

                        Text(statusText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: true, vertical: false)

                    }.frame(maxWidth: .infinity, alignment: .leading).debugJourneyLayoutBox(showLayoutDebug, color: .mint)

                    Text("\(journey.departureStation.name) → \(journey.arrivalStation.name)").font(
                        .subheadline.weight(.medium)
                    )
                    .lineLimit(1)
                    .scalableText(minimumScale: 0.8)
                    .debugJourneyLayoutBox(showLayoutDebug, color: .cyan)
                }.layoutPriority(1).debugJourneyLayoutBox(showLayoutDebug, color: .blue)

                Spacer()

                Button {
                    Haptics.impact(.light)
                    onUnpin()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }.debugJourneyLayoutBox(showLayoutDebug, color: .pink)
            }.debugJourneyLayoutBox(showLayoutDebug, color: .green)

            // Journey timing section
            VStack(spacing: 8) {
                if journey.isInProgress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor).frame(
                                width: geo.size.width * journeyProgress)
                        }
                    }.frame(height: 6)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Departs").font(.caption2).foregroundStyle(.secondary)
                        departureTimeValue
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let departurePlatformLabel {
                            Text("Platform \(departurePlatformLabel)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 16)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Arrival").font(.caption2).foregroundStyle(.secondary)
                        arrivalTimeValue
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let finalArrivalPlatformLabel {
                            Text("Platform \(finalArrivalPlatformLabel)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    if let leaveTime, !journey.hasDeparted {
                        HStack(spacing: 4) {
                            Image(systemName: "figure.walk")
                            Text("Leave \(leaveTime, style: .time)")
                            if let leaveCountdownText {
                                Text(leaveCountdownText)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
                    }

                    if journey.delay > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.exclamationmark")
                            Text("+\(journey.delay) min delay")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
                    }

                    Spacer(minLength: 0)
                }

            }.debugJourneyLayoutBox(showLayoutDebug, color: .yellow)

            // Expand/collapse button
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.88, blendDuration: 0.12)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(isExpanded ? "Hide route" : "Show route").font(.caption.weight(.medium))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption)
                }.foregroundStyle(.secondary)
            }.debugJourneyLayoutBox(showLayoutDebug, color: .teal)
        }.padding(16).debugJourneyLayoutBox(showLayoutDebug, color: .purple)
    }

    private var timelineSection: some View {
        VStack(spacing: 0) {
            let legs = journey.legs.isEmpty ? [createFallbackLeg()] : journey.legs

            ForEach(Array(legs.enumerated()), id: \.element.id) { legIndex, leg in
                // Show leg with its stops
                JourneyLegSection(
                    leg: leg, isFirstLeg: legIndex == 0, isLastLeg: legIndex == legs.count - 1,
                    departureStation: leg.isWalking
                        ? nil : (legIndex == 0 ? journey.departureStation : leg.from),
                    arrivalStation: leg.isWalking
                        ? nil : (legIndex == legs.count - 1 ? journey.arrivalStation : leg.to),
                    arrivalPlatformOverride: legIndex == legs.count - 1 ? finalArrivalPlatformLabel : nil
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
                            nextLineColors: transition.targetLeg.lineColors,
                            currentPlatform: leg.arrivalPlatform ?? leg.platform,
                            nextPlatform: transition.targetLeg.platform,
                            destinationPlatform: transition.targetLeg.arrivalPlatform,
                            incomingDelayMinutes: leg.delayMinutes,
                            nextDepartureTime: transition.targetLeg.departureTime,
                            lineColor: transition.hasUpcomingTransitLeg
                                ? Color.lineColor(
                                    for: transition.targetLeg.lineNumber,
                                    apiColors: transition.targetLeg.lineColors
                                ) : .gray,
                            isPassed: leg.arrivalTime.map { Date() >= $0 } ?? false,
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

private extension View {
    @ViewBuilder
    func debugJourneyLayoutBox(_ enabled: Bool, color: Color) -> some View {
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

// MARK: - JourneyLegSection

private struct JourneyLegSection: View {
    let leg: ConnectionLeg
    let isFirstLeg: Bool
    let isLastLeg: Bool
    let departureStation: Station?
    let arrivalStation: Station?
    let arrivalPlatformOverride: String?

    @Environment(\.colorScheme) var colorScheme

    private var now: Date { Date() }
    private var legLineColor: Color {
        leg.isWalking ? .gray : Color.lineColor(for: leg.lineNumber, apiColors: leg.lineColors)
    }
    private var hasDeparted: Bool { leg.departureTime.map { now >= $0 } ?? false }
    private var hasArrived: Bool { leg.arrivalTime.map { now >= $0 } ?? false }
    private var passedIntermediateStops: [IntermediateStop] {
        leg.intermediateStops.filter { $0.arrivalTime.map { now >= $0 } ?? false }
    }
    private var upcomingIntermediateStops: [IntermediateStop] {
        leg.intermediateStops.filter { !($0.arrivalTime.map { now >= $0 } ?? false) }
    }
    private var visibleIntermediateStops: [IntermediateStop] {
        guard !leg.isWalking else { return [] }
        if hasArrived { return [] }
        if hasDeparted {
            let maxVisibleUpcomingStops = 3
            let upcoming = Array(upcomingIntermediateStops.prefix(maxVisibleUpcomingStops))
            return passedIntermediateStops + upcoming
        }
        return leg.intermediateStops
    }
    private var hiddenUpcomingStopsCount: Int {
        guard hasDeparted, !hasArrived else { return 0 }
        return max(0, upcomingIntermediateStops.count - visibleIntermediateStops.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Show departure endpoint for each transit leg.
            if departureStation != nil {
                JourneyStopRow(
                    name: departureStation?.name ?? leg.from.name, time: leg.departureTime, platform: leg.platform,
                    delay: leg.delayMinutes, lineNumber: leg.lineNumber, lineColors: leg.lineColors, isEndpoint: true,
                    isPassed: leg.departureTime.map { now >= $0 } ?? false, showTopConnector: false,
                    showBottomConnector: true, lineColor: legLineColor, isTransferBoundary: !isFirstLeg
                )
            }

            // Intermediate stops
            if !leg.isWalking {
                ForEach(visibleIntermediateStops) { stop in
                    JourneyStopRow(
                        name: stop.name, time: stop.arrivalTime, platform: nil, delay: stop.arrivalDelay,
                        lineNumber: nil, lineColors: nil, isEndpoint: false,
                        isPassed: stop.arrivalTime.map { now >= $0 } ?? false, showTopConnector: true,
                        showBottomConnector: true, lineColor: legLineColor
                    )
                }

                if hiddenUpcomingStopsCount > 0 {
                    JourneyCollapsedStopsRow(
                        text: "\(hiddenUpcomingStopsCount) more stops", systemImage: "ellipsis.circle",
                        lineColor: legLineColor
                    )
                }
            }

            // Show arrival endpoint for each transit leg.
            if arrivalStation != nil {
                JourneyStopRow(
                    name: arrivalStation?.name ?? leg.to.name, time: leg.arrivalTime,
                    platform: arrivalPlatformOverride ?? leg.arrivalPlatform,
                    delay: nil,
                    lineNumber: nil, lineColors: nil, isEndpoint: true,
                    isPassed: leg.arrivalTime.map { now >= $0 } ?? false, showTopConnector: true,
                    showBottomConnector: false, lineColor: legLineColor, isTransferBoundary: !isLastLeg
                )
            }
        }
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
                Rectangle().fill(lineColor.opacity(0.25)).frame(width: 2, height: 8)
                Circle().fill(
                    colorScheme == .dark ? lineColor.opacity(0.3) : lineColor.opacity(0.16)
                ).frame(width: 6, height: 6)
                Rectangle().fill(lineColor.opacity(0.25)).frame(width: 2, height: 8)
            }.frame(width: 20)

            Label(text, systemImage: systemImage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }.padding(.vertical, 1)
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

    private var endpointConnectorHeight: CGFloat { isTransferBoundary ? 6 : 8 }
    private var endpointNodeDiameter: CGFloat { isTransferBoundary ? 10 : 12 }
    private var endpointNodeStroke: CGFloat { isTransferBoundary ? 1.5 : 2 }

    var body: some View {
        let connectorColor = isPassed ? lineColor : lineColor.opacity(0.35)
        let nodeFillColor =
            isPassed ? lineColor : (colorScheme == .dark ? lineColor.opacity(0.38) : lineColor.opacity(0.22))

        HStack(alignment: .center, spacing: 12) {
            // Timeline indicator
            VStack(spacing: 0) {
                Rectangle().fill(showTopConnector ? connectorColor : .clear).frame(
                    width: 2, height: isEndpoint ? endpointConnectorHeight : 10
                )

                Circle().fill(nodeFillColor).frame(
                    width: isEndpoint ? endpointNodeDiameter : 6, height: isEndpoint ? endpointNodeDiameter : 6
                ).overlay(
                    Circle().stroke(lineColor, lineWidth: isEndpoint ? endpointNodeStroke : 1)
                )

                Rectangle().fill(showBottomConnector ? connectorColor : .clear).frame(
                    width: 2, height: isEndpoint ? endpointConnectorHeight : 10
                )
            }.frame(width: 20)

            // Line badge for departure points
            if let lineNumber, isEndpoint {
                let style = Color.lineBadgeStyle(for: lineNumber, apiColors: lineColors)
                Text(lineNumber)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(style.foreground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(style.background, in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        if let border = style.border {
                            RoundedRectangle(cornerRadius: 4).stroke(border.opacity(0.7), lineWidth: 1)
                        }
                    }
            }

            // Stop info
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.caption.weight(isEndpoint ? .semibold : .regular))
                        .foregroundStyle(isPassed ? .secondary : .primary)
                    if isTransferBoundary {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .lineLimit(1)

                if let time {
                    HStack(spacing: 4) {
                        Text(time, style: .time).font(
                            isEndpoint ? .caption.monospacedDigit().weight(.medium) : .caption2.monospacedDigit()
                        ).foregroundStyle(isPassed ? .secondary : .primary)

                        if let delay, delay > 0 {
                            Text("+\(delay)'").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                        }
                    }
                }
            }

            Spacer()

            if let platform, isEndpoint {
                Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6).padding(
                    .vertical, 2
                ).background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }.padding(.vertical, isEndpoint ? 4 : 1)
    }
}

private struct TopDownRevealModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: max(0.001, progress), anchor: .top)
            .opacity(progress)
            .clipped()
    }
}

private extension AnyTransition {
    static var topDownReveal: AnyTransition {
        .modifier(
            active: TopDownRevealModifier(progress: 0),
            identity: TopDownRevealModifier(progress: 1)
        )
    }
}

#Preview("Single Leg Journey") {
    ScrollView {
        MyJourneyCard(
            journey: PinnedJourney(
                connectionId: "test", lineNumber: "S1", departureTime: Date().addingTimeInterval(-1800),
                arrivalTime: Date().addingTimeInterval(3600),
                departureStation: Station(
                    id: "1", name: "Maribor", coordinate: nil, transportTypes: [.trainCommute], lines: []
                ),
                arrivalStation: Station(
                    id: "2", name: "Graz Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
                ),
                platform: "3", delay: 5, pinnedAt: Date(),
                legs: [
                    ConnectionLeg(
                        from: Station(
                            id: "1", name: "Maribor", coordinate: nil, transportTypes: [.trainCommute], lines: []
                        ),
                        to: Station(
                            id: "2", name: "Graz Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
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
                    id: "1", name: "Maribor", coordinate: nil, transportTypes: [.trainCommute], lines: []
                ),
                arrivalStation: Station(
                    id: "3", name: "Wien Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
                ),
                platform: "3", delay: 0, pinnedAt: Date(),
                legs: [
                    ConnectionLeg(
                        from: Station(
                            id: "1", name: "Maribor", coordinate: nil, transportTypes: [.trainCommute], lines: []
                        ),
                        to: Station(
                            id: "2", name: "Graz Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
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
                            id: "2", name: "Graz Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
                        ),
                        to: Station(
                            id: "3", name: "Wien Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
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
                    id: "1", name: "Ljubljana", coordinate: nil, transportTypes: [.trainCommute], lines: []
                ),
                arrivalStation: Station(
                    id: "3", name: "München Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
                ),
                platform: "1", delay: 0, pinnedAt: Date(),
                legs: [
                    ConnectionLeg(
                        from: Station(
                            id: "1", name: "Ljubljana", coordinate: nil, transportTypes: [.trainCommute], lines: []
                        ),
                        to: Station(
                            id: "2", name: "Villach Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
                        ),
                        departureTime: Date().addingTimeInterval(600), arrivalTime: Date().addingTimeInterval(3000),
                        platform: "1", lineNumber: "IC 515", isWalking: false, duration: 2400, intermediateStops: []
                    ),
                    ConnectionLeg(
                        from: Station(
                            id: "2", name: "Villach Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
                        ),
                        to: Station(
                            id: "3", name: "München Hbf", coordinate: nil, transportTypes: [.trainCommute], lines: []
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
                    transportTypes: [.trainCommute],
                    lines: []
                ),
                arrivalStation: Station(
                    id: "stadlau",
                    name: "Stadlau (Wien)",
                    coordinate: nil,
                    transportTypes: [.trainCommute],
                    lines: []
                ),
                platform: "3",
                delay: 1,
                pinnedAt: Date(),
                legs: [
                    ConnectionLeg(
                        from: Station(id: "graz", name: "Graz", coordinate: nil, transportTypes: [.trainCommute], lines: []),
                        to: Station(
                            id: "stadlau",
                            name: "Stadlau (Wien)",
                            coordinate: nil,
                            transportTypes: [.trainCommute],
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
            onUnpin: {},
            showLayoutDebug: true
        )
        .padding()
    }
    .background(Color(.systemGroupedBackground))
    .frame(width: 380)
}
