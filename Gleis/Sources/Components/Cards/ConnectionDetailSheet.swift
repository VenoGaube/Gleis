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

    @ViewBuilder private var connectionLegs: some View {
        let legs = displayLegs
        VStack(alignment: .leading, spacing: 0) {
            Text("Route").font(.headline).padding(.bottom, 12)
            ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                ConnectionLegRow(leg: leg, showTopConnector: index > 0, showBottomConnector: index < legs.count - 1)
                if index < legs.count - 1, !leg.isWalking, !legs[index + 1].isWalking {
                    TransferRow(
                        stationName: leg.to.name,
                        transferMinutes: transferMinutes(after: index, legs: legs),
                        lineColor: legLineColor(legs[index + 1])
                    )
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

    private func transferMinutes(after index: Int, legs: [ConnectionLeg]) -> Int? {
        guard index < legs.count - 1, let arrival = legs[index].arrivalTime,
              let departure = legs[index + 1].departureTime else { return nil }
        return max(0, Int(departure.timeIntervalSince(arrival) / 60))
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

    var body: some View {
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
    let lineColor: Color

    private var isTightTransfer: Bool { transferMinutes.map { $0 < 5 } ?? false }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(lineColor).frame(width: 2, height: 12)
                Circle().stroke(isTightTransfer ? Color.red : Color.orange, lineWidth: 2).frame(width: 8, height: 8)
                Rectangle().fill(lineColor).frame(width: 2, height: 12)
            }.frame(width: 20)
            HStack(spacing: 8) {
                Image(systemName: isTightTransfer ? "exclamationmark.triangle.fill" : "arrow.down").font(
                    .caption.weight(.semibold)
                ).foregroundStyle(isTightTransfer ? .red : .orange)
                Text("Transfer at \(stationName)").font(.caption.weight(.medium)).foregroundStyle(
                    isTightTransfer ? .red : .primary
                ).scalableText(minimumScale: 0.8)
                Spacer()
                if let transferMinutes {
                    Text("\(transferMinutes) min").font(.caption.weight(isTightTransfer ? .semibold : .regular))
                        .foregroundStyle(isTightTransfer ? .red : .secondary)
                }
            }.padding(.horizontal, 12)
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
