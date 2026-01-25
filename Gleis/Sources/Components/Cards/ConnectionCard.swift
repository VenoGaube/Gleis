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

    var body: some View {
        VStack(spacing: 0) {
            if isMissed, !isExpanded {
                compactMissedView
            } else {
                headerSection
                Divider().background(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
                    .padding(
                        .horizontal,
                        16
                    )
                timeInfoSection
                leaveTimeSection
            }
        }
        .background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: isMissed && !isExpanded ? 12 : 16))
        .overlay(RoundedRectangle(cornerRadius: isMissed && !isExpanded ? 12 : 16).stroke(
            isSelected ? Color
                .accentColor : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.15)),
            lineWidth: isSelected ? 2 : 1
        ))
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 8, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { if isMissed { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } } else { onTap() } }
    }

    private var compactMissedView: some View {
        HStack(spacing: 12) {
            LineBadge(line: connection.lineNumber)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.arrivalStation.name)
                    .font(.subheadline.weight(.medium))
                    .scalableText(minimumScale: 0.8)
                Text(connection.departureTime, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("GO!").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .opacity(0.6)
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            LineBadge(line: connection.lineNumber)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.departureStation.name)
                        .font(.subheadline.weight(.medium))
                        .scalableText(minimumScale: 0.8)
                    if isPinned {
                        PinBadge()
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.caption2)
                    Text(connection.arrivalStation.name)
                        .font(.caption)
                        .scalableText(minimumScale: 0.8)
                }.foregroundStyle(.secondary)
            }
            Spacer()
            if connection.isDelayed { DelayBadge(minutes: connection.delay) }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private var timeInfoSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Departs").font(.caption2.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(connection.departureTime, style: .time).font(.headline.weight(.semibold).monospacedDigit())
            }
            VStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text("\(Int(connection.duration / 60)) min").font(.caption2).foregroundStyle(.secondary)
                if let stops = connection.totalStopCount,
                   stops > 0 { Text("\(stops) stops").font(.caption2).foregroundStyle(.blue) }
                if connection
                    .transfers > 0 { Text("\(connection.transfers)×").font(.caption2).foregroundStyle(.orange) }
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text("Arrives").font(.caption2.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(connection.arrivalTime, style: .time).font(.headline.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
            Divider().frame(height: 40).padding(.leading, 4)
            VStack(spacing: 2) {
                Text("Platform").font(.caption2).foregroundStyle(.secondary)
                Text(connection.platform ?? "—")
                    .font(connection.platform != nil ? .headline.weight(.semibold).monospacedDigit() : .caption2)
                    .foregroundStyle(connection.platform != nil ? .primary : .tertiary)
            }.frame(width: 50)
            if connection.transfers > 0 {
                Button {
                    Haptics.selection()
                    onTap()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(2)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            } else {
                Color.clear.frame(width: 36)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var leaveTimeSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2), lineWidth: 4)
                Circle().trim(from: 0, to: progress).stroke(
                    urgencyColor,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                ).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    if timeRemaining <= 0 {
                        Text("GO!").font(.system(.caption, design: .monospaced).weight(.bold))
                    } else if timeRemaining <= 60 {
                        // Under 1 minute: live countdown with seconds
                        Text(leaveTime, style: .timer)
                            .font(.system(.caption, design: .monospaced).weight(.bold))
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
            }.frame(width: 56, height: 56)
                .accessibilityLabel(countdownAccessibilityLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text("Leave at").font(.caption).foregroundStyle(.secondary)
                Text(leaveTime, style: .time).font(.headline.monospacedDigit()).foregroundStyle(urgencyColor)
            }
            Spacer()

            // Pin button
            Button {
                Haptics.impact(.light)
                isPinned ? onUnpin() : onPin()
            } label: {
                Image(systemName: isPinned ? "pin.slash.fill" : "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPinned ? .white : .secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        isPinned ? Color.accentColor : Color.secondary.opacity(0.15),
                        in: Circle()
                    )
            }
            .disabled(timeRemaining < 0 && !isPinned)
            .accessibilityLabel(isPinned ? "Unpin journey" : "Pin as My Journey")

            // Reminder button
            Button {
                Haptics.impact(.medium)
                isSelected ? onCancel() : onSchedule()
            } label: {
                Image(systemName: isSelected ? "bell.slash.fill" : "bell.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        isSelected ? Color
                            .urgencyRedFallback(colorScheme) : (timeRemaining < 0 ? .secondary : Color.accentColor),
                        in: Circle()
                    )
            }
            .disabled(timeRemaining < 0 && !isSelected)
            .accessibilityLabel(isSelected ? "Cancel reminder" : "Set reminder")
            .accessibilityHint(isSelected ? "Removes the departure notification" :
                "Notifies you when it's time to leave")
        }
        .padding(16).background(urgencyColor.opacity(colorScheme == .dark ? 0.15 : 0.08))
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
        // Truncate to show remaining time (0m appears in final minute)
        let totalMinutes = Int(max(0, seconds) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - LineBadge

struct LineBadge: View {
    let line: String

    var body: some View {
        Text(line.uppercased())
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .scalableText(minimumScale: 0.7)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.lineColor(for: line), in: RoundedRectangle(cornerRadius: 8))
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
        }.font(.caption.weight(.semibold)).foregroundStyle(.orange).padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                Color.orange.opacity(colorScheme == .dark ? 0.25 : 0.15),
                in: Capsule()
            )
    }
}

// MARK: - PinBadge

struct PinBadge: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
            Text("MY JOURNEY")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor, in: Capsule())
    }
}
