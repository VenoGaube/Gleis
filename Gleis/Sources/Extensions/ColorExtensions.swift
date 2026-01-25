import SwiftUI

extension Color {
    // Brand colors
    static let trainBlue = Color(red: 0.0, green: 0.48, blue: 0.85)
    static let settingsSilver = Color(red: 0.55, green: 0.55, blue: 0.58)
    static let sBahnGreen = Color(red: 0.2, green: 0.6, blue: 0.3)

    // Header gradient colors - travel-inspired palette
    static let headerGradientStart = Color(red: 0.12, green: 0.16, blue: 0.32) // Deep midnight blue
    static let headerGradientMid = Color(red: 0.15, green: 0.35, blue: 0.55) // Ocean blue
    static let headerGradientEnd = Color(red: 0.20, green: 0.50, blue: 0.65) // Teal horizon
    static let headerAccent = Color(red: 0.95, green: 0.55, blue: 0.25) // Warm sunset orange

    // Vienna U-Bahn colors
    static let u1Red = Color(red: 0.89, green: 0.15, blue: 0.21)
    static let u2Purple = Color(red: 0.63, green: 0.28, blue: 0.64)
    static let u3Orange = Color(red: 0.94, green: 0.50, blue: 0.13)
    static let u4Green = Color(red: 0.0, green: 0.60, blue: 0.36)
    static let u6Brown = Color(red: 0.55, green: 0.36, blue: 0.24)

    static let regionalTrain = Color(red: 0.7, green: 0.1, blue: 0.1)

    // Line colors
    static func lineColor(for line: String) -> Color {
        let upper = line.uppercased()
        switch upper {
        case "U1": return u1Red
        case "U2": return u2Purple
        case "U3": return u3Orange
        case "U4": return u4Green
        case "U6": return u6Brown
        case _ where upper.hasPrefix("S"): return sBahnGreen
        case _ where upper.hasPrefix("R"): return regionalTrain // Catches R, REX, RJ, RJX
        default: return trainBlue
        }
    }

    // Dark mode adaptive colors
    static let cardBackground = Color("CardBackground")
    static let elevatedBackground = Color("ElevatedBackground")
    static let subtleText = Color("SubtleText")
}

extension View {
    func accentTheme(for _: TransportType) -> some View {
        tint(.trainBlue)
    }

    func cardStyle(colorScheme: ColorScheme) -> some View {
        background(
            colorScheme == .dark
                ? Color(.secondarySystemBackground)
                : Color(.systemBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(
            color: colorScheme == .dark ? .clear : .black.opacity(0.06),
            radius: 8, y: 4
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    colorScheme == .dark ? Color.white.opacity(0.08) : Color.clear,
                    lineWidth: 1
                )
        )
    }
}

// MARK: - AdaptiveBackground

struct AdaptiveBackground: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                colorScheme == .dark
                    ? Color(.systemBackground)
                    : Color(.systemGroupedBackground)
            )
    }
}

extension View {
    func adaptiveBackground() -> some View {
        modifier(AdaptiveBackground())
    }
}
