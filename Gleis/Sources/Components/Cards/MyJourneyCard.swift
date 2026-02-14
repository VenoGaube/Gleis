import SwiftUI

// MARK: - MyJourneyCard

struct MyJourneyCard: View {
    let journey: PinnedJourney
    let onUnpin: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = true

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

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            if isExpanded {
                Divider().background(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
                    .padding(.horizontal, 16)
                timelineSection
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
                LineBadge(line: journey.lineNumber)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("MY JOURNEY").font(.caption.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 8)
                            .padding(.vertical, 4).background(Color.accentColor, in: Capsule())

                        Text(statusText).font(.caption2.weight(.medium)).foregroundStyle(statusColor)

                        if journey.transfers > 0 {
                            Text("\(journey.transfers)×").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }

                    Text("\(journey.departureStation.name) → \(journey.arrivalStation.name)").font(
                        .subheadline.weight(.medium)
                    ).scalableText(minimumScale: 0.8)
                }

                Spacer()

                if journey.delay > 0 { DelayBadge(minutes: journey.delay) }

                Button {
                    Haptics.impact(.light)
                    onUnpin()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }

            // Progress bar for in-progress journeys
            if journey.isInProgress {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor).frame(
                                width: geo.size.width * journeyProgress)
                        }
                    }.frame(height: 6)

                    HStack {
                        Text(journey.departureTime, style: .time).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Arriving \(journey.arrivalTime, style: .time)").font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
            } else if !journey.hasDeparted {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Departs").font(.caption2).foregroundStyle(.secondary)
                        Text(journey.departureTime, style: .time).font(.headline.monospacedDigit())
                    }
                    Spacer()
                    if let platform = journey.platform {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Platform").font(.caption2).foregroundStyle(.secondary)
                            Text(platform).font(.headline.monospacedDigit())
                        }
                    }
                }
            }

            // Expand/collapse button
            Button {
                withAnimation(.spring(response: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(isExpanded ? "Hide route" : "Show route").font(.caption.weight(.medium))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption)
                }.foregroundStyle(.secondary)
            }
        }.padding(16)
    }

    private var timelineSection: some View {
        VStack(spacing: 0) {
            let legs = journey.legs.isEmpty ? [createFallbackLeg()] : journey.legs

            ForEach(Array(legs.enumerated()), id: \.element.id) { legIndex, leg in
                // Show leg with its stops
                JourneyLegSection(
                    leg: leg, isFirstLeg: legIndex == 0, isLastLeg: legIndex == legs.count - 1,
                    departureStation: legIndex == 0 ? journey.departureStation : nil,
                    arrivalStation: legIndex == legs.count - 1 ? journey.arrivalStation : nil
                )

                // Show transfer indicator between legs
                if legIndex < legs.count - 1 {
                    let nextLeg = legs[legIndex + 1]
                    let transferMinutes = calculateTransferTime(from: leg, to: nextLeg)
                    JourneyTransferRow(
                        stationName: leg.to.name, transferMinutes: transferMinutes, nextLineNumber: nextLeg.lineNumber,
                        nextPlatform: nextLeg.platform, isPassed: leg.arrivalTime.map { Date() >= $0 } ?? false
                    )
                }
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }

    private func createFallbackLeg() -> ConnectionLeg {
        ConnectionLeg(
            from: journey.departureStation, to: journey.arrivalStation, departureTime: journey.departureTime,
            arrivalTime: journey.arrivalTime, platform: journey.platform, lineNumber: journey.lineNumber,
            isWalking: false, duration: journey.arrivalTime.timeIntervalSince(journey.departureTime)
        )
    }

    private func calculateTransferTime(from leg: ConnectionLeg, to nextLeg: ConnectionLeg) -> Int? {
        guard let arrival = leg.arrivalTime, let departure = nextLeg.departureTime else { return nil }
        return max(0, Int(departure.timeIntervalSince(arrival) / 60))
    }
}

// MARK: - JourneyLegSection

private struct JourneyLegSection: View {
    let leg: ConnectionLeg
    let isFirstLeg: Bool
    let isLastLeg: Bool
    let departureStation: Station?
    let arrivalStation: Station?

    @Environment(\.colorScheme) var colorScheme

    private var now: Date { Date() }

    var body: some View {
        VStack(spacing: 0) {
            // Departure point (only show for first leg or after transfer)
            if isFirstLeg || departureStation != nil {
                JourneyStopRow(
                    name: departureStation?.name ?? leg.from.name, time: leg.departureTime, platform: leg.platform,
                    delay: leg.delayMinutes, lineNumber: leg.lineNumber, isEndpoint: true,
                    isPassed: leg.departureTime.map { now >= $0 } ?? false, showTopConnector: false,
                    showBottomConnector: true
                )
            }

            // Intermediate stops
            if !leg.isWalking {
                ForEach(leg.intermediateStops) { stop in
                    JourneyStopRow(
                        name: stop.name, time: stop.arrivalTime, platform: stop.platform, delay: stop.arrivalDelay,
                        lineNumber: nil, isEndpoint: false, isPassed: stop.arrivalTime.map { now >= $0 } ?? false,
                        showTopConnector: true, showBottomConnector: true
                    )
                }
            }

            // Arrival point (only show for last leg)
            if isLastLeg {
                JourneyStopRow(
                    name: arrivalStation?.name ?? leg.to.name, time: leg.arrivalTime, platform: nil, delay: nil,
                    lineNumber: nil, isEndpoint: true, isPassed: leg.arrivalTime.map { now >= $0 } ?? false,
                    showTopConnector: true, showBottomConnector: false
                )
            }
        }
    }
}

// MARK: - JourneyStopRow

private struct JourneyStopRow: View {
    let name: String
    let time: Date?
    let platform: String?
    let delay: Int?
    let lineNumber: String?
    let isEndpoint: Bool
    let isPassed: Bool
    let showTopConnector: Bool
    let showBottomConnector: Bool

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Timeline indicator
            VStack(spacing: 0) {
                Rectangle().fill(
                    showTopConnector ? (isPassed ? Color.accentColor : Color.secondary.opacity(0.3)) : .clear
                ).frame(width: 2, height: isEndpoint ? 8 : 10)

                Circle().fill(
                    isPassed ? Color.accentColor : (colorScheme == .dark ? Color(.systemGray4) : Color(.systemGray5))
                ).frame(width: isEndpoint ? 12 : 6, height: isEndpoint ? 12 : 6).overlay(
                    Circle().stroke(
                        isPassed ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: isEndpoint ? 2 : 1
                    ))

                Rectangle().fill(
                    showBottomConnector ? (isPassed ? Color.accentColor : Color.secondary.opacity(0.3)) : .clear
                ).frame(width: 2, height: isEndpoint ? 8 : 10)
            }.frame(width: 20)

            // Line badge for departure points
            if let lineNumber, isEndpoint {
                Text(lineNumber).font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 6).padding(
                    .vertical, 3
                ).background(Color.lineColor(for: lineNumber), in: RoundedRectangle(cornerRadius: 4))
            }

            // Stop info
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(isEndpoint ? .subheadline.weight(.semibold) : .caption).foregroundStyle(
                    isPassed ? .secondary : .primary
                ).lineLimit(1)

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
                Text("Pl. \(platform)").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6).padding(
                    .vertical, 2
                ).background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }.padding(.vertical, isEndpoint ? 4 : 1)
    }
}

// MARK: - JourneyTransferRow

private struct JourneyTransferRow: View {
    let stationName: String
    let transferMinutes: Int?
    let nextLineNumber: String
    let nextPlatform: String?
    let isPassed: Bool

    @Environment(\.colorScheme) var colorScheme

    private var isTightTransfer: Bool { transferMinutes.map { $0 < 5 } ?? false }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Timeline indicator with transfer symbol
            VStack(spacing: 0) {
                Rectangle().fill(isPassed ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 2, height: 8)

                ZStack {
                    Circle().stroke(isTightTransfer ? Color.red : Color.orange, lineWidth: 2).frame(
                        width: 16, height: 16
                    )

                    Image(systemName: "arrow.triangle.swap").font(.system(size: 8, weight: .bold)).foregroundStyle(
                        isTightTransfer ? .red : .orange)
                }

                Rectangle().fill(isPassed ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 2, height: 8)
            }.frame(width: 20)

            // Transfer info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: isTightTransfer ? "exclamationmark.triangle.fill" : "arrow.left.arrow.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(isTightTransfer ? .red : .orange)

                    Text("Transfer at \(stationName)").font(.caption.weight(.medium)).foregroundStyle(
                        isTightTransfer ? .red : (isPassed ? .secondary : .primary)
                    ).lineLimit(1)

                    Spacer()

                    if let transferMinutes {
                        Text("\(transferMinutes) min").font(.caption.weight(isTightTransfer ? .semibold : .regular))
                            .foregroundStyle(isTightTransfer ? .red : .secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text("Change to").font(.caption2).foregroundStyle(.secondary)

                    Text(nextLineNumber).font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 5)
                        .padding(.vertical, 2).background(
                            Color.lineColor(for: nextLineNumber), in: RoundedRectangle(cornerRadius: 3)
                        )

                    if let platform = nextPlatform {
                        Text("Platform \(platform)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.padding(.vertical, 8).padding(.horizontal, 10).background(
                RoundedRectangle(cornerRadius: 8).fill(
                    (isTightTransfer ? Color.red : Color.orange).opacity(colorScheme == .dark ? 0.15 : 0.1)))
        }.padding(.vertical, 4)
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
