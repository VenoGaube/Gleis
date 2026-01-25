import SwiftUI

// MARK: - SmallWidgetUIView

// Shared widget UI component that can be used in both the widget extension and main app
// This ensures the onboarding preview matches the actual widget exactly

struct SmallWidgetUIView: View {
    let lineNumber: String
    let destination: String
    let countdown: String
    let urgencyColor: Color
    let departureTime: String
    let platform: String
    let isPinned: Bool

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            if isPinned {
                Text("MY JOURNEY")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.0, green: 0.48, blue: 0.85), in: Capsule())
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text(lineNumber)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.2, green: 0.6, blue: 0.3), in: RoundedRectangle(cornerRadius: 6))

                    VStack(spacing: 2) {
                        Text(countdown)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(urgencyColor)
                            .contentTransition(.numericText())
                        Text("to leave")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    Text(departureTime)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                    Text("· Pl. \(platform)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Circle().fill(urgencyColor).frame(width: 6, height: 6)
                    Text("Live")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
        }
        .frame(width: 155, height: 155)
        .background(colorScheme == .dark ? Color(.secondarySystemBackground) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

// Helper to format countdown time
func formatCountdownTime(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
        return "0:\(String(format: "%02d", Int(seconds)))"
    } else {
        let minutes = Int(seconds / 60)
        return "\(minutes)m"
    }
}

// Helper to determine urgency color based on remaining time
func urgencyColor(for seconds: TimeInterval) -> Color {
    if seconds <= 0 {
        .secondary
    } else if seconds < 120 {
        .red
    } else if seconds < 300 {
        .orange
    } else {
        .green
    }
}
