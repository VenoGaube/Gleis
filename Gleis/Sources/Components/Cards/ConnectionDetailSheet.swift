import SwiftUI

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
                        let walkDurationMinutes = ConnectionTransferPlanner.walkingDurationMinutes(for: transition.walkingLegs)
                        TransferRow(
                            stationName: leg.to.name,
                            transferMinutes: walkDurationMinutes
                                ?? ConnectionTransferPlanner.transferMinutes(from: leg, to: transition.targetLeg),
                            walkDurationMinutes: walkDurationMinutes,
                            nextLineNumber: transition.targetLeg.lineNumber,
                            nextLineColors: transition.targetLeg.lineColors,
                            currentPlatform: normalizedPlatform(leg.arrivalPlatform) ?? normalizedPlatform(leg.platform),
                            nextPlatform: normalizedPlatform(transition.targetLeg.platform),
                            incomingDelayMinutes: leg.delayMinutes,
                            nextDepartureTime: transition.targetLeg.departureTime,
                            lineColor: transition.nextLegIsWalking ? .gray : legLineColor(transition.targetLeg),
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
        normalizedPlatform(firstTravelLeg?.platform) ?? normalizedPlatform(resolvedConnection.platform)
    }

    private var summaryArrivalPlatform: String? {
        normalizedPlatform(lastTravelLeg?.arrivalPlatform)
    }

    private func normalizedPlatform(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
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

    private var inBetweenStopCount: Int? {
        if let stopCount = leg.stopCount { return stopCount }
        return leg.intermediateStops.isEmpty ? nil : leg.intermediateStops.count
    }

    private var railColor: Color {
        guard !leg.isWalking else { return .gray }
        return Color.lineColor(for: leg.lineNumber, apiColors: leg.lineColors)
    }

    private var departurePlatform: String? {
        normalizedPlatform(leg.platform)
    }

    private var arrivalPlatform: String? {
        normalizedPlatform(leg.arrivalPlatform)
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

    private func normalizedPlatform(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

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
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(showTopConnector ? railColor : .clear).frame(width: 2, height: 8)
                Circle().fill(railColor).frame(width: 8, height: 8)
                Rectangle().fill(showBottomConnector ? railColor : .clear).frame(width: 2)
            }.frame(width: 20)

            HStack(spacing: 10) {
                Image(systemName: "figure.walk").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(walkingTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let walkingDurationMinutes {
                        Text("\(walkingDurationMinutes) min walk").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private var fullLegBody: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(showTopConnector ? railColor : .clear).frame(width: 2, height: 8)
                Circle().fill(railColor).frame(width: 10, height: 10)
                Rectangle().fill(showBottomConnector ? railColor : .clear).frame(width: 2)
            }.frame(width: 20)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    legBadge
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: leg.isWalking ? "figure.walk" : "train.side.front.car").font(.caption)
                                .foregroundStyle(.secondary)
                            Text(leg.isWalking ? "WALK" : leg.lineNumber).font(.caption).foregroundStyle(.secondary)

                            if let destination = leg.finalDestination, !leg.isWalking {
                                Text("→ \(destination)").font(.caption).foregroundStyle(.tertiary).scalableText(
                                    minimumScale: 0.8)
                            }
                            Spacer()
                            if let duration = leg.duration, !leg.isWalking {
                                Text("\(Int(duration / 60)) min").font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        if let stops = inBetweenStopCount, stops > 0, !leg.isWalking {
                            Text("\(stops) in-between stops").font(.caption2).foregroundStyle(.blue)
                        }

                        if let delay = leg.delayMinutes, delay > 0, !leg.isWalking {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.badge.exclamationmark").font(.caption2)
                                Text("+\(delay) min delay").font(.caption2)
                            }.foregroundStyle(.orange)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stopEntries.enumerated()), id: \.element.id) { index, stop in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(spacing: 0) {
                                Rectangle().fill(index == 0 ? .clear : railColor.opacity(0.75)).frame(
                                    width: 2, height: 8
                                )
                                Circle().fill(railColor).frame(
                                    width: stop.isEndpoint ? 8 : 6,
                                    height: stop.isEndpoint ? 8 : 6
                                )
                                Rectangle().fill(index == stopEntries.count - 1 ? .clear : railColor.opacity(0.75))
                                    .frame(width: 2, height: 8)
                            }.frame(width: 12)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(stop.name).font(.subheadline.weight(stop.isEndpoint ? .semibold : .regular))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    TimeText(date: stop.time)
                                }

                                if let platform = stop.platform {
                                    HStack(spacing: 4) {
                                        Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary)
                                        if stop.showChangedBadge {
                                            Text("(changed)").font(.caption2).foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(10)
                .background(
                    colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .padding(12)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
    }

    @ViewBuilder private var legBadge: some View {
        if leg.isWalking {
            Image(systemName: "figure.walk").font(.headline).foregroundStyle(.white).frame(width: 44, height: 36)
                .background(Color.gray, in: RoundedRectangle(cornerRadius: 8))
        } else {
            LineBadge(line: leg.lineNumber, colors: leg.lineColors)
        }
    }
}

// MARK: - TransferRow

struct TransferRow: View {
    let stationName: String
    let transferMinutes: Int?
    let walkDurationMinutes: Int?
    let nextLineNumber: String
    let nextLineColors: TrainLineColors?
    let currentPlatform: String?
    let nextPlatform: String?
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
        if involvesWalking { return .walking }
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
        if nextLegIsWalking {
            return hasUpcomingTransitLeg ? "Walk to your next train" : "Walk to destination"
        }
        return "Change to \(normalizedNextLine ?? "next connection")"
    }
    private var riskBadgeText: String {
        guard let transferMinutes else { return urgency.label }
        return "\(urgency.label) · \(transferMinutes) min"
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
        return "Pl. \(from) -> \(to)"
    }
    private var detailsText: String {
        if let nextPlatform = normalizedNextPlatform {
            return "at \(stationName) · board from Platform \(nextPlatform)"
        }
        return "at \(stationName)"
    }
    private var compactWalkingTitle: String {
        if !hasUpcomingTransitLeg {
            if let platform = normalizedNextPlatform { return "Walk to Platform \(platform)" }
            return "Walk to destination"
        }
        if let platform = normalizedNextPlatform, let line = normalizedNextLine {
            return "Walk to Pl. \(platform) for \(line)"
        }
        if let platform = normalizedNextPlatform { return "Walk to Platform \(platform)" }
        if let line = normalizedNextLine { return "Walk to \(line)" }
        return "Walk transfer at \(stationName)"
    }
    private var compactWalkingMeta: String? {
        if let walkDurationMinutes { return "\(walkDurationMinutes) min walk" }
        if let transferMinutes { return "\(transferMinutes) min walk" }
        return nil
    }
    private var shouldShowMetaRow: Bool { platformChangeText != nil || nextDepartureTime != nil }

    var body: some View {
        if involvesWalking { compactWalkingBody } else { fullTransferBody }
    }

    private var compactWalkingBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(isPassed ? lineColor : lineColor.opacity(0.35)).frame(width: 2, height: 12)
                Circle().stroke(Color.secondary, lineWidth: 2).frame(width: 12, height: 12).overlay(
                    Image(systemName: "figure.walk")
                        .font(.system(size: 6, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                )
                Rectangle().fill(isPassed ? lineColor : lineColor.opacity(0.35)).frame(width: 2, height: 12)
            }.frame(width: 20)

            HStack(spacing: 8) {
                Text(compactWalkingTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPassed ? .secondary : .primary)
                    .lineLimit(1)

                Spacer()

                if let compactWalkingMeta {
                    Text(compactWalkingMeta)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
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
                Rectangle().fill(isPassed ? lineColor : lineColor.opacity(0.35)).frame(width: 2, height: 12)

                ZStack {
                    Circle().stroke(indicatorColor, lineWidth: 2).frame(width: 12, height: 12)
                    Image(systemName: transferIconName).font(.system(size: 6, weight: .bold)).foregroundStyle(
                        indicatorColor)
                }

                Rectangle().fill(isPassed ? lineColor : lineColor.opacity(0.35)).frame(width: 2, height: 12)
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

                    Text(riskBadgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(indicatorColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(indicatorColor.opacity(colorScheme == .dark ? 0.2 : 0.12), in: Capsule())
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

                if let nextLine = normalizedNextLine {
                    HStack(spacing: 6) {
                        Text("Board").font(.caption2).foregroundStyle(.secondary)

                        let style = Color.lineBadgeStyle(for: nextLine, apiColors: nextLineColors)
                        Text(nextLine)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(style.foreground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(style.background, in: RoundedRectangle(cornerRadius: 3))
                            .overlay {
                                if let border = style.border {
                                    RoundedRectangle(cornerRadius: 3).stroke(border.opacity(0.7), lineWidth: 1)
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(indicatorColor.opacity(colorScheme == .dark ? 0.16 : 0.1))
            )
        }
    }
}

// MARK: - TimeText

struct TimeText: View {
    let date: Date?
    var body: some View {
        if let date {
            Text(date, style: .time).font(.subheadline.monospacedDigit())
        } else {
            Text("--").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
