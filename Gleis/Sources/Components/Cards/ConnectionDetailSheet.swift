import SwiftUI

// MARK: - ConnectionDetailSheet

struct ConnectionDetailSheet: View {
    let connection: TrainConnection
    let onRefresh: (() async -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(connection: TrainConnection, onRefresh: (() async -> Void)? = nil) {
        self.connection = connection
        self.onRefresh = onRefresh
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionSummary
                    connectionLegs
                }.padding()
            }
            .refreshable { await onRefresh?() }
            .navigationTitle("Connection Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LineBadge(line: connection.lineNumber)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(connection.departureStation.name) to \(connection.arrivalStation.name)")
                        .font(.subheadline.weight(.semibold))
                        .scalableText(minimumScale: 0.7)
                    Text("\(Int(connection.duration / 60)) min total").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if connection
                    .transfers >
                    0
                {
                    Text("\(connection.transfers) transfers").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Depart").font(.caption2).foregroundStyle(.secondary)
                    Text(connection.departureTime, style: .time).font(.headline.monospacedDigit())
                    if let platform = connection.platform,
                       !platform.isEmpty { Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Arrive").font(.caption2).foregroundStyle(.secondary)
                    Text(connection.arrivalTime, style: .time).font(.headline.monospacedDigit())
                }
            }
        }.padding(16).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var connectionLegs: some View {
        let legs = displayLegs
        VStack(alignment: .leading, spacing: 0) {
            Text("Route").font(.headline).padding(.bottom, 12)
            ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                ConnectionLegRow(leg: leg, showTopConnector: index > 0, showBottomConnector: index < legs.count - 1)
                if index < legs.count - 1, !leg.isWalking, !legs[index + 1].isWalking {
                    TransferRow(stationName: leg.to.name, transferMinutes: transferMinutes(after: index, legs: legs))
                }
            }
        }
    }

    private var displayLegs: [ConnectionLeg] {
        if connection.legs.isEmpty {
            return [ConnectionLeg(
                from: connection.departureStation,
                to: connection.arrivalStation,
                departureTime: connection.departureTime,
                arrivalTime: connection.arrivalTime,
                platform: connection.platform,
                lineNumber: connection.lineNumber,
                isWalking: false,
                duration: connection.duration
            )]
        }
        return connection.legs
    }

    private func transferMinutes(after index: Int, legs: [ConnectionLeg]) -> Int? {
        guard index < legs.count - 1, let arrival = legs[index].arrivalTime,
              let departure = legs[index + 1].departureTime else { return nil }
        return max(0, Int(departure.timeIntervalSince(arrival) / 60))
    }
}

// MARK: - ConnectionLegRow

struct ConnectionLegRow: View {
    let leg: ConnectionLeg
    var showTopConnector: Bool = false
    var showBottomConnector: Bool = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Timeline connector
            VStack(spacing: 0) {
                Rectangle().fill(showTopConnector ? Color.accentColor : .clear).frame(width: 2, height: 8)
                Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                Rectangle().fill(showBottomConnector ? Color.accentColor : .clear).frame(width: 2)
            }.frame(width: 20)

            HStack(alignment: .top, spacing: 12) {
                legBadge
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(leg.from.name)
                            .font(.subheadline.weight(.semibold))
                            .scalableText(minimumScale: 0.8)
                        Spacer()
                        TimeText(date: leg.departureTime)
                    }
                    HStack {
                        Image(systemName: leg.isWalking ? "figure.walk" : "train.side.front.car").font(.caption)
                            .foregroundStyle(.secondary)
                        Text(leg.isWalking ? "WALK" : leg.lineNumber).font(.caption).foregroundStyle(.secondary)

                        if let stops = leg.stopCount, stops > 0,
                           !leg.isWalking { Text("\(stops) stops").font(.caption2).foregroundStyle(.blue) }
                        if let destination = leg.finalDestination, !leg.isWalking {
                            Text("→ \(destination)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .scalableText(minimumScale: 0.8)
                        }
                        Spacer()
                        if let duration = leg.duration,
                           !leg
                               .isWalking
                        {
                            Text("\(Int(duration / 60)) min").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let delay = leg.delayMinutes, delay > 0, !leg.isWalking {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.exclamationmark").font(.caption2)
                            Text("+\(delay) min delay").font(.caption2)
                        }.foregroundStyle(.orange)
                    }
                    HStack {
                        Text(leg.to.name)
                            .font(.subheadline.weight(.semibold))
                            .scalableText(minimumScale: 0.8)
                        Spacer()
                        TimeText(date: leg.arrivalTime)
                    }
                    if let platform = leg.platform, !platform.isEmpty {
                        HStack(spacing: 4) {
                            Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary)
                            if leg.platformChanged { Text("(changed)").font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                }
            }.padding(12).background(
                colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
    }

    @ViewBuilder
    private var legBadge: some View {
        if leg.isWalking {
            Image(systemName: "figure.walk").font(.headline).foregroundStyle(.white).frame(width: 44, height: 36)
                .background(
                    Color.gray,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        } else {
            LineBadge(line: leg.lineNumber)
        }
    }
}

// MARK: - TransferRow

struct TransferRow: View {
    let stationName: String
    let transferMinutes: Int?

    private var isTightTransfer: Bool { transferMinutes.map { $0 < 5 } ?? false }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: 2, height: 12)
                Circle().stroke(isTightTransfer ? Color.red : Color.orange, lineWidth: 2).frame(width: 8, height: 8)
                Rectangle().fill(Color.accentColor).frame(width: 2, height: 12)
            }.frame(width: 20)
            HStack(spacing: 8) {
                Image(systemName: isTightTransfer ? "exclamationmark.triangle.fill" : "arrow.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(isTightTransfer ? .red : .orange)
                Text("Transfer at \(stationName)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isTightTransfer ? .red : .primary)
                    .scalableText(minimumScale: 0.8)
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
        if let date { Text(date, style: .time).font(.subheadline.monospacedDigit()) }
        else { Text("--").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
    }
}
