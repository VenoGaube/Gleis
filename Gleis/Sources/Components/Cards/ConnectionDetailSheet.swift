import SwiftUI

// MARK: - ConnectionDetailSheet

struct ConnectionDetailSheet: View {
    let connection: TrainConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var resolvedConnection: TrainConnection
    @State private var isLoadingDetails = false
    @State private var hasLoadedDetails = false
    @State private var isShowingSeats = false

    init(connection: TrainConnection) {
        self.connection = connection
        _resolvedConnection = State(initialValue: connection)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionSummary
                    if hasReservableLeg { viewSeatsButton }
                    serviceAlertsSection
                    connectionLegs
                }
                .padding()
            }
            .refreshable { await loadConnectionDetailsIfNeeded(force: true) }
            .navigationTitle("Connection Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: connection.id) { await loadConnectionDetailsIfNeeded() }
        .sheet(isPresented: $isShowingSeats) {
            SeatMapSheet(connection: resolvedConnection)
                .presentationDetents([.large])
        }
    }

    private var stacksForAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryHeader
            if isLoadingDetails {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading stops")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            departArriveRow
        }.padding(16).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var summaryHeader: some View {
        let layout = stacksForAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            LineBadge(line: resolvedConnection.lineNumber, colors: resolvedConnection.lineColors)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(resolvedConnection.departureStation.name) to \(resolvedConnection.arrivalStation.name)")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Int(resolvedConnection.duration / 60)) min total").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let changesText {
                Text(changesText).font(.caption.weight(.semibold)).foregroundStyle(.orange).fixedSize()
            }
        }
    }

    private var changesText: String? {
        switch resolvedConnection.transfers {
        case ...0: return nil
        case 1: return "1 change"
        default: return "\(resolvedConnection.transfers) changes"
        }
    }

    private var departArriveRow: some View {
        // Side by side while it fits, stacked otherwise, so times never split mid-word.
        ViewThatFits(in: .horizontal) {
            HStack {
                departsColumn(alignment: .leading)
                Spacer()
                arrivesColumn(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 12) {
                departsColumn(alignment: .leading)
                arrivesColumn(alignment: .leading)
            }
        }
    }

    private func departsColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text("Departs").font(.caption2).foregroundStyle(.secondary)
            DelayedTimeText(
                time: resolvedConnection.departureTime, delayMinutes: resolvedConnection.delay, alignment: alignment
            )
            if let platform = summaryDeparturePlatform {
                Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func arrivesColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text("Arrives").font(.caption2).foregroundStyle(.secondary)
            DelayedTimeText(
                time: resolvedConnection.arrivalTime, delayMinutes: resolvedConnection.delay, alignment: alignment
            )
            if let platform = summaryArrivalPlatform {
                Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var hasReservableLeg: Bool { displayLegs.contains { !$0.isWalking } }

    private var viewSeatsButton: some View {
        Button { isShowingSeats = true } label: {
            Label {
                Text("View Seats").fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "carseat.right")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var serviceAlertsSection: some View {
        let alerts = (resolvedConnection.serviceAlerts ?? []).filter(\.isActive).sorted { $0.priority > $1.priority }
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Service Alerts").font(.headline)
                }
                ForEach(alerts) { alert in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(alert.title).font(.subheadline.weight(.semibold))
                        if !alert.message.isEmpty {
                            Text(alert.message).font(.caption).foregroundStyle(.secondary)
                        }
                        if let endsAt = alert.endsAt {
                            Text("Until \(endsAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder private var connectionLegs: some View {
        let legs = displayLegs
        VStack(alignment: .leading, spacing: 0) {
            Text("Route").font(.headline).padding(.bottom, 12)
            ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                if !leg.isWalking || legs.count == 1 {
                    ConnectionLegRow(
                        leg: leg, showTopConnector: index > 0, showBottomConnector: index < legs.count - 1
                    )
                }
                if index < legs.count - 1, !(leg.isWalking && index > 0) {
                    if let transition = ConnectionTransferPlanner.context(after: index, legs: legs) {
                        TransferRow(
                            stationName: leg.to.name,
                            transferMinutes: ConnectionTransferPlanner.transferMinutes(from: leg, to: transition.targetLeg),
                            nextLineNumber: transition.targetLeg.lineNumber,
                            currentPlatform: leg.arrivalPlatform.trimmedNonEmpty ?? leg.platform.trimmedNonEmpty,
                            nextPlatform: transition.targetLeg.platform.trimmedNonEmpty,
                            nextDepartureTime: transition.targetLeg.departureTime,
                            lineColor: transition.targetLeg.displayLineColor,
                            isPassed: leg.arrivalTime.map { Date() >= $0 } ?? false,
                            involvesWalking: transition.involvesWalking,
                            nextLegIsWalking: transition.nextLegIsWalking,
                            hasUpcomingTransitLeg: transition.hasUpcomingTransitLeg
                        )
                    }
                }
            }
        }
    }

    private var displayLegs: [ConnectionLeg] {
        if resolvedConnection.legs.isEmpty {
            return [
                ConnectionLeg(
                    from: resolvedConnection.departureStation, to: resolvedConnection.arrivalStation,
                    departureTime: resolvedConnection.departureTime, arrivalTime: resolvedConnection.arrivalTime,
                    platform: resolvedConnection.platform, arrivalPlatform: nil, lineNumber: resolvedConnection.lineNumber,
                    isWalking: false,
                    duration: resolvedConnection.duration
                ),
            ]
        }
        return resolvedConnection.legs
    }

    @MainActor
    private func loadConnectionDetailsIfNeeded(force: Bool = false) async {
        guard !isLoadingDetails else { return }
        if hasLoadedDetails && !force { return }
        if !force, hasUsableIntermediateData {
            hasLoadedDetails = true
            return
        }

        isLoadingDetails = true
        defer {
            isLoadingDetails = false
            hasLoadedDetails = true
        }

        do {
            resolvedConnection = try await TransportService.shared.enrichConnectionDetails(resolvedConnection)
        } catch {
            // Keep base connection data if detail endpoint is unavailable for this connection.
        }
    }

    private var hasUsableIntermediateData: Bool {
        resolvedConnection.legs.contains { leg in
            !leg.isWalking && !leg.intermediateStops.isEmpty
        }
    }

    private var firstTravelLeg: ConnectionLeg? {
        let legs = displayLegs
        return legs.first { !$0.isWalking } ?? legs.first
    }

    private var lastTravelLeg: ConnectionLeg? {
        let legs = displayLegs
        return legs.last { !$0.isWalking } ?? legs.last
    }

    private var summaryDeparturePlatform: String? {
        firstTravelLeg?.platform.trimmedNonEmpty ?? resolvedConnection.platform.trimmedNonEmpty
    }

    private var summaryArrivalPlatform: String? {
        lastTravelLeg?.arrivalPlatform.trimmedNonEmpty
    }

}

// MARK: - ConnectionLegRow

struct ConnectionLegRow: View {
    let leg: ConnectionLeg
    var showTopConnector: Bool = false
    var showBottomConnector: Bool = false
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var railWidth: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var endpointNodeSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var stopNodeSize: CGFloat = 6
    @ScaledMetric(relativeTo: .caption) private var walkNodeSize: CGFloat = 10

    private struct LegStopEntry: Identifiable {
        let id: String
        let name: String
        let time: Date?
        let scheduledTime: Date?
        let delayMinutes: Int?
        let platform: String?
        let isEndpoint: Bool
        let showChangedBadge: Bool
    }

    private var railColor: Color { leg.displayLineColor }

    private var departurePlatform: String? {
        leg.platform.trimmedNonEmpty
    }

    private var arrivalPlatform: String? {
        leg.arrivalPlatform.trimmedNonEmpty
    }

    private var stopEntries: [LegStopEntry] {
        var entries: [LegStopEntry] = [
            LegStopEntry(
                id: "\(leg.id)-dep",
                name: leg.from.name,
                time: leg.departureTime,
                scheduledTime: scheduledTimeIfDelayed(
                    from: leg.departureTime,
                    delayMinutes: leg.departureDelayMinutes ?? leg.delayMinutes
                ),
                delayMinutes: leg.departureDelayMinutes ?? leg.delayMinutes,
                platform: departurePlatform,
                isEndpoint: true,
                showChangedBadge: leg.platformChanged
            )
        ]

        entries.append(
            contentsOf: leg.intermediateStops.map {
                let displayTime = $0.arrivalTime ?? $0.departureTime
                let displayDelay = $0.arrivalTime != nil ? $0.arrivalDelay : $0.departureDelay
                return LegStopEntry(
                    id: $0.id,
                    name: $0.name,
                    time: displayTime,
                    scheduledTime: scheduledTimeIfDelayed(from: displayTime, delayMinutes: displayDelay),
                    delayMinutes: displayDelay,
                    platform: nil,
                    isEndpoint: false,
                    showChangedBadge: false
                )
            }
        )

        entries.append(
            LegStopEntry(
                id: "\(leg.id)-arr",
                name: leg.to.name,
                time: leg.arrivalTime,
                scheduledTime: scheduledTimeIfDelayed(
                    from: leg.arrivalTime,
                    delayMinutes: leg.arrivalDelayMinutes ?? leg.delayMinutes
                ),
                delayMinutes: leg.arrivalDelayMinutes ?? leg.delayMinutes,
                platform: arrivalPlatform,
                isEndpoint: true,
                showChangedBadge: false
            )
        )

        return entries
    }

    private var now: Date { Date() }

    private var walkingDurationMinutes: Int? {
        ConnectionTransferPlanner.walkingDurationMinutes(for: leg)
    }

    private var walkingTitle: String {
        if let arrivalPlatform { return "Walk to Platform \(arrivalPlatform)" }
        if leg.from.name != leg.to.name { return "Walk to \(leg.to.name)" }
        return "Walk to your next platform"
    }

    var body: some View {
        if leg.isWalking { compactWalkingBody } else { fullLegBody }
    }

    private var compactWalkingBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                railSegment(fill: showTopConnector ? railColor.opacity(0.6) : .clear, height: 10)
                Circle()
                    .stroke(railColor.opacity(0.7), lineWidth: 2)
                    .frame(width: walkNodeSize, height: walkNodeSize)
                railSegment(fill: showBottomConnector ? railColor.opacity(0.6) : .clear, height: 10)
            }.frame(width: railWidth)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    walkingTitleText
                    Spacer()
                    walkingDurationText
                }
                VStack(alignment: .leading, spacing: 2) {
                    walkingTitleText
                    walkingDurationText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .padding(.vertical, 2)
    }

    private var walkingTitleText: some View {
        Text(walkingTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var walkingDurationText: some View {
        if let walkingDurationMinutes {
            Text("\(walkingDurationMinutes) min")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func railSegment(fill: Color, height: CGFloat) -> some View {
        Rectangle().fill(fill).frame(width: 2, height: height)
    }

    private var fullLegBody: some View {
        let entries = stopEntries
        return VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, stop in
                stopRow(stop: stop, index: index, isLast: index == entries.count - 1)
            }
        }
    }

    private func stopRow(stop: LegStopEntry, index: Int, isLast: Bool) -> some View {
        let isFirst = index == 0
        let isPassed = stop.time.map { now >= $0 } ?? false
        let connectorColor = isPassed ? railColor : railColor.opacity(0.35)
        let nodeFillColor = isPassed ? railColor : (colorScheme == .dark ? railColor.opacity(0.4) : railColor.opacity(0.22))

        // Stacks from xxxLarge so long stop names get the full width instead of splitting mid-word.
        let stacksBadgeAndPlatform = dynamicTypeSize >= .xxxLarge
        let nodeSize = stop.isEndpoint ? endpointNodeSize : stopNodeSize

        return HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                railSegment(
                    fill: (isFirst ? showTopConnector : true) ? connectorColor : .clear,
                    height: stop.isEndpoint ? 8 : 10
                )

                Circle()
                    .fill(nodeFillColor)
                    .frame(width: nodeSize, height: nodeSize)
                    .overlay(Circle().stroke(railColor, lineWidth: stop.isEndpoint ? 2 : 1))

                railSegment(
                    fill: (isLast ? showBottomConnector : true) ? connectorColor : .clear,
                    height: stop.isEndpoint ? 8 : 10
                )
            }
            .frame(width: railWidth)

            if isFirst, !stacksBadgeAndPlatform { legLineBadge.fixedSize() }

            VStack(alignment: .leading, spacing: 1) {
                if isFirst, stacksBadgeAndPlatform { legLineBadge.padding(.bottom, 2) }

                Text(stop.name)
                    .font(.caption.weight(stop.isEndpoint ? .semibold : .regular))
                    .foregroundStyle(isPassed ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { stopTimeDetails(stop: stop, isPassed: isPassed) }
                    VStack(alignment: .leading, spacing: 1) { stopTimeDetails(stop: stop, isPassed: isPassed) }
                }

                if stacksBadgeAndPlatform, let platform = stop.platform, stop.isEndpoint {
                    platformCapsule(platform).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !stacksBadgeAndPlatform, let platform = stop.platform, stop.isEndpoint {
                platformCapsule(platform).fixedSize()
            }
        }
        .padding(.vertical, stop.isEndpoint ? 5 : 2)
    }

    private var legLineBadge: some View {
        let style = Color.lineBadgeStyle(for: leg.lineNumber, apiColors: leg.lineColors)
        return Text(leg.lineNumber)
            .font(.caption2.weight(.bold))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(style.background, in: RoundedRectangle(cornerRadius: 5))
    }

    private func platformCapsule(_ platform: String) -> some View {
        Text("Platform \(platform)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.08), in: Capsule())
    }

    @ViewBuilder private func stopTimeDetails(stop: LegStopEntry, isPassed: Bool) -> some View {
        if let scheduledTime = stop.scheduledTime {
            Text(scheduledTime, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .strikethrough()
        }

        if let time = stop.time {
            Text(time, style: .time)
                .font(stop.isEndpoint ? .subheadline.monospacedDigit().weight(.semibold) : .caption.monospacedDigit())
                .foregroundStyle(isPassed ? .secondary : .primary)
        }

        if let delayMinutes = stop.delayMinutes, delayMinutes > 0 {
            Text("+\(delayMinutes) min")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
        }

        if stop.showChangedBadge {
            Text("(changed)")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - TransferRow

struct TransferRow: View {
    let stationName: String
    let transferMinutes: Int?
    let nextLineNumber: String
    let currentPlatform: String?
    let nextPlatform: String?
    let nextDepartureTime: Date?
    let lineColor: Color
    let isPassed: Bool
    let involvesWalking: Bool
    let nextLegIsWalking: Bool
    let hasUpcomingTransitLeg: Bool

    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .caption) private var railWidth: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var nodeSize: CGFloat = 12

    private enum TransferUrgency {
        case walking
        case comfortable
        case tight
        case critical
        case missed
        case unknown

        var color: Color {
            switch self {
            case .walking, .unknown: return .secondary
            case .comfortable:
                return Self.paletteColor(
                    light: (31 / 255, 138 / 255, 59 / 255),
                    dark: (48 / 255, 209 / 255, 88 / 255)
                )
            case .tight:
                return Self.paletteColor(
                    light: (178 / 255, 106 / 255, 0 / 255),
                    dark: (1, 159 / 255, 10 / 255)
                )
            case .critical:
                return Self.paletteColor(
                    light: (209 / 255, 73 / 255, 0 / 255),
                    dark: (1, 122 / 255, 0)
                )
            case .missed:
                return Self.paletteColor(
                    light: (215 / 255, 0, 21 / 255),
                    dark: (1, 69 / 255, 58 / 255)
                )
            }
        }

        var icon: String {
            switch self {
            case .walking: return "figure.walk"
            case .comfortable: return "checkmark.circle"
            case .tight: return "exclamationmark.triangle"
            case .critical: return "clock.badge.exclamationmark"
            case .missed: return "xmark.octagon"
            case .unknown: return "questionmark.circle"
            }
        }

        private static func paletteColor(
            light: (CGFloat, CGFloat, CGFloat),
            dark: (CGFloat, CGFloat, CGFloat)
        ) -> Color {
            Color(
                uiColor: UIColor { traits in
                    let rgb = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
                }
            )
        }
    }

    private var urgency: TransferUrgency {
        if involvesWalking && !hasUpcomingTransitLeg { return .walking }
        guard let transferMinutes else { return .unknown }
        if transferMinutes <= 0 { return .missed }
        if transferMinutes < 5 { return .critical }
        if transferMinutes <= 8 { return .tight }
        return .comfortable
    }
    private var indicatorColor: Color { urgency.color }
    private var transferIconName: String { urgency.icon }
    private var normalizedNextLine: String? {
        let trimmed = nextLineNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        guard upper != "W" && upper != "WALK" else { return nil }
        return trimmed
    }
    private var transferTitle: String {
        if nextLegIsWalking, !hasUpcomingTransitLeg { return "Walk to destination" }
        if urgency == .missed { return "Missed change at \(stationName)" }
        return "Change at \(stationName)"
    }
    private var riskBadgeText: String? {
        if urgency == .missed { return "Missed" }
        guard let transferMinutes else { return nil }
        return "\(transferMinutes) min"
    }
    private var summaryTextColor: Color {
        if isPassed { return .secondary }
        switch urgency {
        case .tight, .critical, .missed: return indicatorColor
        default: return .primary
        }
    }
    private var normalizedCurrentPlatform: String? { currentPlatform.trimmedNonEmpty }
    private var normalizedNextPlatform: String? { nextPlatform.trimmedNonEmpty }
    private var platformChange: (from: String, to: String)? {
        guard let from = normalizedCurrentPlatform, let to = normalizedNextPlatform, from != to else { return nil }
        return (from, to)
    }
    private var detailsText: String {
        if urgency == .missed {
            return "This delay will likely make you miss \(normalizedNextLine ?? "your next train"). Pull down to see other trains."
        }
        let changeText = "Change to \(normalizedNextLine ?? "your next train")"
        if let nextPlatform = normalizedNextPlatform {
            return "\(changeText) at Platform \(nextPlatform)"
        }
        return changeText
    }
    private var compactWalkingTitle: String {
        if !hasUpcomingTransitLeg {
            if let platform = normalizedNextPlatform { return "Walk to Platform \(platform)" }
            return "Walk to destination"
        }
        if let platform = normalizedNextPlatform, let line = normalizedNextLine {
            return "Walk to Platform \(platform) for \(line)"
        }
        if let platform = normalizedNextPlatform { return "Walk to Platform \(platform)" }
        if let line = normalizedNextLine { return "Walk to \(line)" }
        return "Walk to your next platform at \(stationName)"
    }
    private var connectorSegmentHeight: CGFloat { 24 }
    private var shouldShowMetaRow: Bool { platformChange != nil || nextDepartureTime != nil }

    var body: some View {
        Group {
            if involvesWalking && !hasUpcomingTransitLeg {
                compactWalkingBody
            } else {
                fullTransferBody
            }
        }
        .padding(.vertical, 3)
    }

    private var railSegment: some View {
        Rectangle()
            .fill(isPassed ? lineColor : lineColor.opacity(0.35))
            .frame(width: 2, height: connectorSegmentHeight)
    }

    private var compactWalkingBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                railSegment
                Circle().stroke(Color.secondary, lineWidth: 2).frame(width: nodeSize, height: nodeSize).overlay(
                    Image(systemName: "figure.walk")
                        .font(.system(size: nodeSize / 2, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                )
                railSegment
            }.frame(width: railWidth)

            Text(compactWalkingTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isPassed ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(colorScheme == .dark ? 0.14 : 0.08))
            )
        }
    }

    private var fullTransferBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                railSegment

                ZStack {
                    Circle().stroke(indicatorColor, lineWidth: 2).frame(width: nodeSize, height: nodeSize)
                    Image(systemName: transferIconName).font(.system(size: nodeSize / 2, weight: .bold)).foregroundStyle(
                        indicatorColor)
                }

                railSegment
            }.frame(width: railWidth)

            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        transferTitleLabel
                        Spacer()
                        riskBadge
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        transferTitleLabel
                        riskBadge
                    }
                }

                Text(detailsText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if shouldShowMetaRow {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { transferMetaItems }
                        VStack(alignment: .leading, spacing: 4) { transferMetaItems }
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(indicatorColor.opacity(colorScheme == .dark ? 0.18 : 0.1))
            )
        }
    }

    private var transferTitleLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: transferIconName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(indicatorColor)
            Text(transferTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(summaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var riskBadge: some View {
        if let riskBadgeText {
            Text(riskBadgeText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(indicatorColor, in: Capsule())
        }
    }

    @ViewBuilder private var transferMetaItems: some View {
        if let platformChange {
            (Text("Platform \(platformChange.from) ") + Text(Image(systemName: "arrow.right")) + Text(" \(platformChange.to)"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(colorScheme == .dark ? 0.18 : 0.1), in: Capsule())
                .accessibilityLabel("Platform \(platformChange.from) to platform \(platformChange.to)")
        }

        if let nextDepartureTime {
            HStack(spacing: 6) {
                Text("Departs").font(.caption2).foregroundStyle(.secondary)
                Text(nextDepartureTime, style: .time)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(isPassed ? .secondary : .primary)
            }
        }
    }
}
