import Foundation
import SwiftUI

/// Pre-computed display data for a connection, optimized to avoid repeated calculations in views
struct DisplayConnection: Identifiable {
    let connection: TrainConnection
    let leaveTime: Date
    let isSelected: Bool
    let isPinned: Bool

    // Phase flags, moved forward by the view model at each phase boundary rather than every second
    private(set) var isLeaveWindowPassed: Bool
    private(set) var hasDeparted: Bool
    /// True once the leave time is at most `leaveCountdownWindow` away, passed included.
    private(set) var isWithinLeaveCountdownWindow: Bool

    var id: String { connection.id }

    init(connection: TrainConnection, leaveTime: Date, isSelected: Bool, isPinned: Bool, currentTime: Date = Date()) {
        self.connection = connection
        self.leaveTime = leaveTime
        self.isSelected = isSelected
        self.isPinned = isPinned
        let phase = Self.connectionPhase(
            leaveTime: leaveTime,
            departureTime: connection.departureTime,
            currentTime: currentTime
        )
        isLeaveWindowPassed = phase.isLeaveWindowPassed
        hasDeparted = phase.hasDeparted
        isWithinLeaveCountdownWindow = phase.isWithinLeaveCountdownWindow
    }

    func timeRemaining(at date: Date) -> TimeInterval {
        leaveTime.timeIntervalSince(date)
    }

    func urgencyColor(at date: Date) -> Color {
        Color.urgency(for: timeRemaining(at: date))
    }

    func progress(at date: Date) -> Double {
        max(0, min(1, timeRemaining(at: date) / 1800))
    }

    /// Recomputes the phase flags at `currentTime` and returns whether any of them changed.
    mutating func updatePhase(at currentTime: Date) -> Bool {
        let phase = Self.connectionPhase(
            leaveTime: leaveTime,
            departureTime: connection.departureTime,
            currentTime: currentTime
        )
        let current = Phase(
            isLeaveWindowPassed: isLeaveWindowPassed,
            hasDeparted: hasDeparted,
            isWithinLeaveCountdownWindow: isWithinLeaveCountdownWindow
        )
        guard phase != current else { return false }
        isLeaveWindowPassed = phase.isLeaveWindowPassed
        hasDeparted = phase.hasDeparted
        isWithinLeaveCountdownWindow = phase.isWithinLeaveCountdownWindow
        return true
    }

    /// Plays the 5-min, 2-min or leave-now haptic if the countdown crossed one between the two times.
    func playThresholdHaptic(from previousTime: Date, to currentTime: Date) {
        // Haptics only for a journey the user committed to. Firing them for every
        // visible connection meant a buzz each time any of ~25 rows crossed a
        // threshold, for trains the user is not taking.
        guard isSelected || isPinned else { return }
        let previousRemaining = timeRemaining(at: previousTime)
        let newRemaining = timeRemaining(at: currentTime)
        if previousRemaining >= Self.warningHapticLeadTime, newRemaining < Self.warningHapticLeadTime {
            Haptics.notification(.warning)
        } else if previousRemaining >= Self.finalHapticLeadTime, newRemaining < Self.finalHapticLeadTime {
            Haptics.notification(.error)
        } else if previousRemaining >= 0, newRemaining < 0 {
            Haptics.notification(.error)
        }
    }

    /// The next time after `date` at which a phase flag flips or a threshold haptic is due.
    func nextPhaseBoundary(after date: Date) -> Date? {
        var boundaries = [leaveTime, connection.departureTime, leaveTime.addingTimeInterval(-Self.leaveCountdownWindow)]
        if isSelected || isPinned {
            boundaries += [
                leaveTime.addingTimeInterval(-Self.warningHapticLeadTime),
                leaveTime.addingTimeInterval(-Self.finalHapticLeadTime),
            ]
        }
        return boundaries.filter { $0 > date }.min()
    }

    // MARK: - Static Helpers

    /// How far ahead a leave time gets a live countdown and a full card instead of a static time.
    static let leaveCountdownWindow: TimeInterval = 60 * 60
    private static let warningHapticLeadTime: TimeInterval = 300
    private static let finalHapticLeadTime: TimeInterval = 120

    private struct Phase: Equatable {
        let isLeaveWindowPassed: Bool
        let hasDeparted: Bool
        let isWithinLeaveCountdownWindow: Bool
    }

    private static func connectionPhase(
        leaveTime: Date,
        departureTime: Date,
        currentTime: Date
    ) -> Phase {
        let hasDeparted = currentTime >= departureTime
        return Phase(
            isLeaveWindowPassed: currentTime >= leaveTime && !hasDeparted,
            hasDeparted: hasDeparted,
            isWithinLeaveCountdownWindow: leaveTime.timeIntervalSince(currentTime) <= leaveCountdownWindow
        )
    }
}
