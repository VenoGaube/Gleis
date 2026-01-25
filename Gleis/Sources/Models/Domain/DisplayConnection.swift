import Foundation
import SwiftUI

/// Pre-computed display data for a connection, optimized to avoid repeated calculations in views
struct DisplayConnection: Identifiable {
    let connection: TrainConnection
    let leaveTime: Date
    let isSelected: Bool
    let isPinned: Bool

    // Time-based properties (updated by centralized timer)
    var timeRemaining: TimeInterval
    var urgencyColor: Color
    var progress: Double
    var isMissed: Bool { timeRemaining <= 0 }

    var id: String { connection.id }

    init(connection: TrainConnection, leaveTime: Date, isSelected: Bool, isPinned: Bool, currentTime: Date = Date()) {
        self.connection = connection
        self.leaveTime = leaveTime
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.timeRemaining = leaveTime.timeIntervalSince(currentTime)
        self.urgencyColor = Self.calculateUrgencyColor(timeRemaining: timeRemaining)
        self.progress = Self.calculateProgress(timeRemaining: timeRemaining)
    }

    /// Update time-based properties with current time (called by centralized timer)
    mutating func updateTime(currentTime: Date) {
        let newRemaining = leaveTime.timeIntervalSince(currentTime)

        // Only trigger haptics on threshold crossings
        if timeRemaining >= 300, newRemaining < 300 {
            Haptics.notification(.warning)
        } else if timeRemaining >= 120, newRemaining < 120 {
            Haptics.notification(.error)
        } else if timeRemaining >= 0, newRemaining < 0 {
            Haptics.notification(.error)
        }

        timeRemaining = newRemaining
        urgencyColor = Self.calculateUrgencyColor(timeRemaining: newRemaining)
        progress = Self.calculateProgress(timeRemaining: newRemaining)
    }

    // MARK: - Static Helpers

    private static func calculateUrgencyColor(timeRemaining: TimeInterval) -> Color {
        if timeRemaining <= 0 { return .secondary }
        if timeRemaining < 120 { return .urgencyRed }
        if timeRemaining < 300 { return .urgencyOrange }
        return .urgencyGreen
    }

    private static func calculateProgress(timeRemaining: TimeInterval) -> Double {
        max(0, min(1, timeRemaining / 1800))
    }
}
