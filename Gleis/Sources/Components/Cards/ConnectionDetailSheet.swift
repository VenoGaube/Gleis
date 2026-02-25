import SwiftUI

private func normalizedPlatformValue(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty else { return nil }
    return trimmed
}

// MARK: - ConnectionDetailSheet

struct ConnectionDetailSheet: View {
    let connection: TrainConnection
    let onRefresh: (() async -> Void)?
    private let transportService: TransportService
    @Environment(\.dismiss) private var dismiss
    @State private var resolvedConnection: TrainConnection
    @State private var isLoadingDetails = false
    @State private var hasLoadedDetails = false

    init(
        connection: TrainConnection, onRefresh: (() async -> Void)? = nil,
        transportService: TransportService = .shared
    ) {
        self.connection = connection
        self.onRefresh = onRefresh
        self.transportService = transportService
        _resolvedConnection = State(initialValue: connection)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionSummary
                    serviceAlertsSection
                    connectionLegs
                }
                .padding()
            }
            .refreshable { await refreshContent() }
            .navigationTitle("Connection Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: connection.id) { await loadConnectionDetailsIfNeeded() }
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LineBadge(line: resolvedConnection.lineNumber, colors: resolvedConnection.lineColors)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(resolvedConnection.departureStation.name) to \(resolvedConnection.arrivalStation.name)").font(
                        .subheadline.weight(.semibold)
                    ).scalableText(minimumScale: 0.7)
                    Text("\(Int(resolvedConnection.duration / 60)) min total").font(.caption).foregroundStyle(
                        .secondary
                    )
                }
                Spacer()
                if resolvedConnection.transfers > 0 {
                    Text("\(resolvedConnection.transfers) transfers").font(.caption.weight(.semibold)).foregroundStyle(
                        .orange
                    )
                }
            }
            if isLoadingDetails {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading intermediate stops")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Depart").font(.caption2).foregroundStyle(.secondary)
                    Text(resolvedConnection.departureTime, style: .time).font(.headline.monospacedDigit())
                    if let platform = summaryDeparturePlatform {
                        Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Arrive").font(.caption2).foregroundStyle(.secondary)
                    Text(resolvedConnection.arrivalTime, style: .time).font(.headline.monospacedDigit())
                    if let platform = summaryArrivalPlatform {
                        Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(16).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
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
                            nextLineColors: transition.targetLeg.lineColors,
                            currentPlatform: normalizedPlatformValue(leg.arrivalPlatform)
                                ?? normalizedPlatformValue(leg.platform),
                            nextPlatform: normalizedPlatformValue(transition.targetLeg.platform),
                            destinationPlatform: normalizedPlatformValue(transition.targetLeg.arrivalPlatform),
                            incomingDelayMinutes: leg.delayMinutes,
                            nextDepartureTime: transition.targetLeg.departureTime,
                            lineColor: transition.hasUpcomingTransitLeg ? legLineColor(transition.targetLeg) : .gray,
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
    private func refreshContent() async {
        await onRefresh?()
        await loadConnectionDetailsIfNeeded(force: true)
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
            resolvedConnection = try await transportService.enrichConnectionDetails(resolvedConnection)
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
        displayLegs.first { !$0.isWalking } ?? displayLegs.first
    }

    private var lastTravelLeg: ConnectionLeg? {
        displayLegs.last { !$0.isWalking } ?? displayLegs.last
    }

    private var summaryDeparturePlatform: String? {
        normalizedPlatformValue(firstTravelLeg?.platform) ?? normalizedPlatformValue(resolvedConnection.platform)
    }

    private var summaryArrivalPlatform: String? {
        normalizedPlatformValue(lastTravelLeg?.arrivalPlatform)
    }

    private func legLineColor(_ leg: ConnectionLeg) -> Color {
        guard !leg.isWalking else { return .gray }
        return Color.lineColor(for: leg.lineNumber, apiColors: leg.lineColors)
    }
}

// MARK: - ConnectionLegRow

struct ConnectionLegRow: View {
    let leg: ConnectionLeg
    var showTopConnector: Bool = false
    var showBottomConnector: Bool = false
    @Environment(\.colorScheme) var colorScheme

    private struct LegStopEntry: Identifiable {
        let id: String
        let name: String
        let time: Date?
        let platform: String?
        let isEndpoint: Bool
        let showChangedBadge: Bool
    }

    private var railColor: Color {
        guard !leg.isWalking else { return .gray }
        return Color.lineColor(for: leg.lineNumber, apiColors: leg.lineColors)
    }

    private var departurePlatform: String? {
        normalizedPlatformValue(leg.platform)
    }

    private var arrivalPlatform: String? {
        normalizedPlatformValue(leg.arrivalPlatform)
    }

    private var stopEntries: [LegStopEntry] {
        var entries: [LegStopEntry] = [
            LegStopEntry(
                id: "\(leg.id)-dep",
                name: leg.from.name,
                time: leg.departureTime,
                platform: departurePlatform,
                isEndpoint: true,
                showChangedBadge: leg.platformChanged
            )
        ]

        entries.append(
            contentsOf: leg.intermediateStops.map {
                LegStopEntry(
                    id: $0.id,
                    name: $0.name,
                    time: $0.arrivalTime ?? $0.departureTime,
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
        return "Walk to transfer point"
    }

    var body: some View {
        if leg.isWalking { compactWalkingBody } else { fullLegBody }
    }

    private var compactWalkingBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(showTopConnector ? railColor.opacity(0.6) : .clear).frame(width: 2, height: 10)
                Circle()
                    .stroke(railColor.opacity(0.7), lineWidth: 2)
                    .frame(width: 10, height: 10)
                Rectangle().fill(showBottomConnector ? railColor.opacity(0.6) : .clear).frame(width: 2, height: 10)
            }.frame(width: 20)

            HStack(spacing: 8) {
                Text(walkingTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let walkingDurationMinutes {
                    Text("\(walkingDurationMinutes) min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

    private var fullLegBody: some View {
        VStack(spacing: 0) {
            ForEach(Array(stopEntries.enumerated()), id: \.element.id) { index, stop in
                stopRow(stop: stop, index: index)
            }
        }
    }

    private func stopRow(stop: LegStopEntry, index: Int) -> some View {
        let isFirst = index == 0
        let isLast = index == stopEntries.count - 1
        let isPassed = stop.time.map { now >= $0 } ?? false
        let connectorColor = isPassed ? railColor : railColor.opacity(0.35)
        let nodeFillColor = isPassed ? railColor : (colorScheme == .dark ? railColor.opacity(0.4) : railColor.opacity(0.22))

        return HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill((isFirst ? showTopConnector : true) ? connectorColor : .clear)
                    .frame(width: 2, height: stop.isEndpoint ? 8 : 10)

                Circle()
                    .fill(nodeFillColor)
                    .frame(width: stop.isEndpoint ? 12 : 6, height: stop.isEndpoint ? 12 : 6)
                    .overlay(Circle().stroke(railColor, lineWidth: stop.isEndpoint ? 2 : 1))

                Rectangle()
                    .fill((isLast ? showBottomConnector : true) ? connectorColor : .clear)
                    .frame(width: 2, height: stop.isEndpoint ? 8 : 10)
            }
            .frame(width: 20)

            if isFirst {
                let style = Color.lineBadgeStyle(for: leg.lineNumber, apiColors: leg.lineColors)
                Text(leg.lineNumber)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(style.foreground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(style.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        if let border = style.border {
                            RoundedRectangle(cornerRadius: 5).stroke(border.opacity(0.7), lineWidth: 1)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(stop.name)
                    .font(.caption.weight(stop.isEndpoint ? .semibold : .regular))
                    .foregroundStyle(isPassed ? .secondary : .primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let time = stop.time {
                        Text(time, style: .time)
                            .font(stop.isEndpoint ? .subheadline.monospacedDigit().weight(.semibold) : .caption.monospacedDigit())
                            .foregroundStyle(isPassed ? .secondary : .primary)
                    }

                    if stop.showChangedBadge {
                        Text("(changed)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if let platform = stop.platform, stop.isEndpoint {
                Text("Platform \(platform)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.08), in: Capsule())
            }
        }
        .padding(.vertical, stop.isEndpoint ? 5 : 2)
    }
}

// MARK: - TransferRow

struct TransferRow: View {
    let stationName: String
    let transferMinutes: Int?
    let nextLineNumber: String
    let nextLineColors: TrainLineColors?
    let currentPlatform: String?
    let nextPlatform: String?
    let destinationPlatform: String?
    let incomingDelayMinutes: Int?
    let nextDepartureTime: Date?
    let lineColor: Color
    let isPassed: Bool
    let involvesWalking: Bool
    let nextLegIsWalking: Bool
    let hasUpcomingTransitLeg: Bool

    @Environment(\.colorScheme) var colorScheme

    private enum TransferUrgency {
        case walking
        case comfortable
        case tight
        case critical
        case unknown

        var color: Color {
            switch self {
            case .walking, .unknown: return .secondary
            case .comfortable: return .green
            case .tight: return .orange
            case .critical: return .red
            }
        }

        var icon: String {
            switch self {
            case .walking: return "figure.walk"
            case .comfortable: return "checkmark.circle.fill"
            case .tight: return "exclamationmark.triangle.fill"
            case .critical: return "exclamationmark.octagon.fill"
            case .unknown: return "questionmark.circle"
            }
        }

        var label: String {
            switch self {
            case .walking: return "Walk"
            case .comfortable: return "Comfortable"
            case .tight: return "Tight"
            case .critical: return "Critical"
            case .unknown: return "Check"
            }
        }
    }

    private var urgency: TransferUrgency {
        if involvesWalking && !hasUpcomingTransitLeg { return .walking }
        guard let transferMinutes else { return .unknown }
        let effectiveTransfer = max(0, transferMinutes - max(0, incomingDelayMinutes ?? 0))
        if effectiveTransfer <= 3 { return .critical }
        if effectiveTransfer <= 7 { return .tight }
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
        return "Transfer at \(stationName)"
    }
    private var riskBadgeText: String? {
        guard let transferMinutes else { return nil }
        return "\(transferMinutes) min"
    }
    private var summaryTextColor: Color {
        if isPassed { return .secondary }
        switch urgency {
        case .critical: return .red
        default: return .primary
        }
    }
    private var normalizedCurrentPlatform: String? {
        let trimmed = currentPlatform?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
    private var normalizedNextPlatform: String? {
        let trimmed = nextPlatform?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
    private var platformChangeText: String? {
        guard let from = normalizedCurrentPlatform, let to = normalizedNextPlatform, from != to else { return nil }
        return "Platform \(from) -> \(to)"
    }
    private var detailsText: String {
        let changeText = "Change to \(normalizedNextLine ?? "next connection")"
        if let nextPlatform = normalizedNextPlatform {
            return "\(changeText) · board from Platform \(nextPlatform)"
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
        return "Walk transfer at \(stationName)"
    }
    private var connectorSegmentHeight: CGFloat { 24 }
    private var shouldShowMetaRow: Bool { platformChangeText != nil || nextDepartureTime != nil }

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

    private var compactWalkingBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(isPassed ? lineColor : lineColor.opacity(0.35)).frame(
                    width: 2,
                    height: connectorSegmentHeight
                )
                Circle().stroke(Color.secondary, lineWidth: 2).frame(width: 12, height: 12).overlay(
                    Image(systemName: "figure.walk")
                        .font(.system(size: 6, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                )
                Rectangle().fill(isPassed ? lineColor : lineColor.opacity(0.35)).frame(
                    width: 2,
                    height: connectorSegmentHeight
                )
            }.frame(width: 20)

            HStack(spacing: 8) {
                Text(compactWalkingTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPassed ? .secondary : .primary)
                    .lineLimit(1)

                Spacer()
            }
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
                Rectangle().fill(isPassed ? lineColor : lineColor.opacity(0.35)).frame(
                    width: 2,
                    height: connectorSegmentHeight
                )

                ZStack {
                    Circle().stroke(indicatorColor, lineWidth: 2).frame(width: 12, height: 12)
                    Image(systemName: transferIconName).font(.system(size: 6, weight: .bold)).foregroundStyle(
                        indicatorColor)
                }

                Rectangle().fill(isPassed ? lineColor : lineColor.opacity(0.35)).frame(
                    width: 2,
                    height: connectorSegmentHeight
                )
            }.frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: transferIconName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(indicatorColor)
                    Text(transferTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(summaryTextColor)
                        .scalableText(minimumScale: 0.8)
                        .lineLimit(1)

                    Spacer()

                    if let riskBadgeText {
                        Text(riskBadgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(indicatorColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(indicatorColor.opacity(colorScheme == .dark ? 0.2 : 0.12), in: Capsule())
                    }
                }

                Text(detailsText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if shouldShowMetaRow {
                    HStack(spacing: 6) {
                        if let platformChangeText {
                            Text(platformChangeText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(colorScheme == .dark ? 0.18 : 0.1), in: Capsule())
                        }

                        if let nextDepartureTime {
                            Text("Departs").font(.caption2).foregroundStyle(.secondary)
                            Text(nextDepartureTime, style: .time)
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(isPassed ? .secondary : .primary)
                        }

                        Spacer()
                    }
                }

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(indicatorColor.opacity(colorScheme == .dark ? 0.18 : 0.1))
            )
        }
    }
}
