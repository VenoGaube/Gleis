import SwiftUI

struct LineBadgeStyle {
    let background: Color
    let foreground: Color
    let border: Color?
}

extension Color {
    // Brand colors
    static let trainBlue = Color(red: 0.0, green: 0.48, blue: 0.85)
    static let sBahnGreen = Color(red: 0.2, green: 0.6, blue: 0.3)
    static let repeatLeaveChip = Color(red: 0.12, green: 0.31, blue: 0.55) // #1F4E8C
    static let repeatNotificationChip = Color(red: 0.0, green: 0.34, blue: 0.82) // #0057D2
    static let repeatSuggestionText = Color(red: 0.72, green: 0.37, blue: 0.0) // #B85E00

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

    static func lineColor(for line: String, apiColors: TrainLineColors?) -> Color {
        lineBadgeStyle(for: line, apiColors: apiColors).background
    }

    static func lineBadgeStyle(for line: String, apiColors: TrainLineColors?) -> LineBadgeStyle {
        let fallbackBackground = lineColor(for: line)
        guard let apiColors else { return LineBadgeStyle(background: fallbackBackground, foreground: .white, border: nil) }

        // Prefer the accent/bar color so the full badge background is the train color (not white API backgrounds).
        let backgroundHex = apiColors.accentHex ?? apiColors.backgroundHex
        let background = color(fromHex: backgroundHex) ?? fallbackBackground
        return LineBadgeStyle(background: background, foreground: .white, border: nil)
    }

    private static func color(fromHex hex: String?) -> Color? {
        guard let hex, let components = rgbComponents(forHex: hex) else { return nil }
        return Color(
            red: Double(components.red) / 255,
            green: Double(components.green) / 255,
            blue: Double(components.blue) / 255
        )
    }

    private static func rgbComponents(forHex hex: String) -> (red: Int, green: Int, blue: Int)? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        if raw.count == 3 {
            raw = raw.map { "\($0)\($0)" }.joined()
        }
        guard raw.count == 6 || raw.count == 8 else { return nil }

        let rgb = raw.count == 8 ? String(raw.dropFirst(2)) : raw
        guard let value = Int(rgb, radix: 16) else { return nil }
        return (red: (value >> 16) & 0xFF, green: (value >> 8) & 0xFF, blue: value & 0xFF)
    }

    // Dark mode adaptive colors
    static let cardBackground = Color("CardBackground")
}

extension View {
    func accentTheme(for _: TransportType) -> some View { tint(.trainBlue) }
}
