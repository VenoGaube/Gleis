import Foundation
import SwiftUI

// MARK: - ScalableText

/// ViewModifier for scalable text that shrinks to fit available space
struct ScalableText: ViewModifier {
    let minimumScaleFactor: CGFloat

    init(minimumScaleFactor: CGFloat = 0.5) { self.minimumScaleFactor = minimumScaleFactor }

    func body(content: Content) -> some View { content.minimumScaleFactor(minimumScaleFactor).lineLimit(1) }
}

extension View {
    /// Makes text scalable, shrinking to fit available space if needed
    func scalableText(minimumScale: CGFloat = 0.5) -> some View {
        modifier(ScalableText(minimumScaleFactor: minimumScale))
    }
}

// MARK: - Motion

extension Animation {
    /// The house spring for every expand, collapse and tab pill move. Critically damped, so it never overshoots.
    static let gleisToggle: Animation = .spring(response: 0.35, dampingFraction: 1)
    /// Insert, remove and reorder of list rows.
    static let gleisList: Animation = .snappy(duration: 0.35)
}

/// The cross-fade used in place of a moving animation when Reduce Motion is on.
private let reducedMotionFade: Animation = .easeInOut(duration: 0.2)

// MARK: - Semantic Colors

extension Color {
    /// Urgency colors for countdown displays
    static func urgency(for remainingSeconds: TimeInterval, colorScheme _: ColorScheme = .light) -> Color {
        if remainingSeconds <= 0 { return .secondary }
        if remainingSeconds < 120 { return .urgencyRed }
        if remainingSeconds < 300 { return .urgencyOrange }
        return .urgencyGreen
    }

    /// Semantic urgency colors that adapt to light/dark mode
    static var urgencyRed: Color { .red }
    static var urgencyOrange: Color { .orange }
    static var urgencyGreen: Color { .green }

    /// Fallback urgency colors when asset catalog colors aren't available
    static func urgencyRedFallback(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 1.0, green: 0.3, blue: 0.3) : .red
    }

    /// Full-screen background behind a tab or sheet.
    static func screenBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)
    }

    /// Fill for a card sitting on the screen background.
    static func cardSurface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground)
    }
}

extension ConnectionLeg {
    /// Gray for a walking leg, otherwise the line's own colour.
    var displayLineColor: Color { isWalking ? .gray : Color.lineColor(for: lineNumber, apiColors: lineColors) }
}

// MARK: - Display Helpers

extension Optional where Wrapped == String {
    /// The trimmed string, or nil when nothing is left after trimming.
    var trimmedNonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The timetable time behind a delayed time, or nil when there is no delay to strike through.
func scheduledTimeIfDelayed(from time: Date?, delayMinutes: Int?) -> Date? {
    guard let delayMinutes, delayMinutes > 0 else { return nil }
    return ConnectionTransferPlanner.plannedTime(from: time, delayMinutes: delayMinutes)
}

/// A headline time that shows the struck-through timetable time beside it, in orange, when delayed.
struct DelayedTimeText: View {
    let time: Date
    let delayMinutes: Int
    var weight: Font.Weight? = nil
    /// Where the two times line up when they are too wide to sit side by side and stack instead.
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        if let scheduled = scheduledTimeIfDelayed(from: time, delayMinutes: delayMinutes) {
            let scheduledText = Text(scheduled, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .strikethrough()
                .fixedSize()
            let liveText = Text(time, style: .time)
                .font(.headline.monospacedDigit())
                .fontWeight(weight ?? .semibold)
                .foregroundStyle(.orange)
                .fixedSize()
            // fixedSize keeps each time whole, so the pair stacks rather than splitting "7:56 PM" across lines.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    scheduledText
                    liveText
                }
                VStack(alignment: alignment, spacing: 2) {
                    scheduledText
                    liveText
                }
            }
        } else {
            Text(time, style: .time).font(.headline.monospacedDigit()).fontWeight(weight ?? .semibold).fixedSize()
        }
    }
}

// MARK: - TabItem

struct TabItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let icon: String
    let selectedIcon: String

    init(id: Int, title: String, icon: String, selectedIcon: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.selectedIcon = selectedIcon ?? icon
    }
}

// MARK: - CustomTabBar

struct CustomTabBar: View {
    @Binding var selectedTab: Int
    let tabs: [TabItem]
    let accentColor: Color
    var onTabTap: ((Int) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabAnimation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                CustomTabBarButton(
                    tab: tab, isSelected: selectedTab == tab.id, accentColor: accentColor, pillNamespace: tabAnimation
                ) {
                    onTabTap?(tab.id)
                    // The paged TabView only slides when the selection change itself is animated.
                    withAnimation(tabAnimationCurve) { selectedTab = tab.id }
                }
            }
        }.padding(.horizontal, 16).padding(.top, 16)
            .padding(.bottom, 16)
            // Keyed on the value rather than the tap, so a page swipe moves the pill too.
            .animation(tabAnimationCurve, value: selectedTab)
            // Like the system tab bar, text stops growing here and long-press shows the large content viewer.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .background(
                Rectangle().fill(colorScheme == .dark ? Color(.systemBackground) : .white).shadow(
                    color: .black.opacity(0.08), radius: 12, y: -4
                ).ignoresSafeArea(edges: .bottom))
    }

    private var tabAnimationCurve: Animation { reduceMotion ? reducedMotionFade : .gleisToggle }
}

/// One tab. Its own view so the scaled sizes read the tab bar's capped type size.
private struct CustomTabBarButton: View {
    let tab: TabItem
    let isSelected: Bool
    let accentColor: Color
    let pillNamespace: Namespace.ID
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var pillWidth: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var pillHeight: CGFloat = 32

    var body: some View {
        let iconName = isSelected ? tab.selectedIcon : tab.icon

        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if isSelected { selectionPill }

                    Image(systemName: iconName).font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .secondary).scaleEffect(isSelected ? 1.0 : 0.9)
                }.frame(minHeight: pillHeight)

                Text(tab.title).font(.caption).fontWeight(isSelected ? .semibold : .medium).foregroundStyle(
                    isSelected ? accentColor : .secondary
                ).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(TabButtonStyle())
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityShowsLargeContentViewer {
                Label(tab.title, systemImage: iconName)
            }
    }

    @ViewBuilder private var selectionPill: some View {
        let pill = Capsule().fill(accentColor).frame(width: pillWidth, height: pillHeight)
            .shadow(color: accentColor.opacity(0.4), radius: 8, y: 2)
        if reduceMotion {
            pill.transition(.opacity)
        } else {
            pill.matchedGeometryEffect(id: "tabPill", in: pillNamespace)
        }
    }
}

// MARK: - TabButtonStyle

struct TabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TabButtonPressBody(configuration: configuration)
    }
}

/// ButtonStyle cannot read the environment itself, so the press body does it.
private struct TabButtonPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressScale: CGFloat = reduceMotion ? 1.0 : 0.94
        configuration.label.scaleEffect(configuration.isPressed ? pressScale : 1.0).opacity(
            configuration.isPressed ? 0.85 : 1.0
        ).animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Haptics

enum Haptics {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    // Each call re-prepares its generator so the next tap fires without the cold-start lag.
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = impactGenerator(for: style)
        generator.impactOccurred()
        generator.prepare()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    private static func impactGenerator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        switch style {
        case .light: lightImpact
        case .heavy: heavyImpact
        case .soft: softImpact
        case .rigid: rigidImpact
        default: mediumImpact
        }
    }
}

// MARK: - SkeletonBox

/// A static placeholder block. Apply `.skeletonShimmer()` to the row or card that holds the boxes.
struct SkeletonBox: View {
    var width: CGFloat?
    var height: CGFloat = 16
    var cornerRadius: CGFloat = 4
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.isSkeletonMaskPass) private var isSkeletonMaskPass

    private var fillColor: Color {
        isSkeletonMaskPass ? .black : Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(fillColor).frame(width: width, height: height)
    }
}

private struct SkeletonMaskPassKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    /// True inside the shimmer's mask copy, where boxes fill opaque so the band keeps its full strength.
    var isSkeletonMaskPass: Bool {
        get { self[SkeletonMaskPassKey.self] }
        set { self[SkeletonMaskPassKey.self] = newValue }
    }
}

// MARK: - SkeletonShimmer

/// Sweeps one highlight band across every skeleton box in the modified view.
private struct SkeletonShimmer: ViewModifier {
    private static let sweepDuration: TimeInterval = 1.5
    private static let bandWidth: CGFloat = 60

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.overlay {
                // Phase comes from the clock, so every shimmering view on screen sweeps in step.
                TimelineView(.animation) { context in
                    GeometryReader { geo in
                        let elapsed = context.date.timeIntervalSinceReferenceDate
                        let phase = elapsed.truncatingRemainder(dividingBy: Self.sweepDuration) / Self.sweepDuration
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.3), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        ).frame(width: Self.bandWidth)
                            .offset(x: -Self.bandWidth + CGFloat(phase) * (geo.size.width + Self.bandWidth))
                    }
                }.mask { content.environment(\.isSkeletonMaskPass, true) }.allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func skeletonShimmer() -> some View { modifier(SkeletonShimmer()) }
}

// MARK: - ConnectionsLoadingView

/// The wait shown when there is no cached timetable to fall back on.
///
/// The provider takes 5-8s to answer a trip search, and longer on a busy route, so a
/// bare shimmer leaves the user unsure whether anything is happening. This says what
/// is being waited on, and admits it when the wait runs long rather than looking stuck.
struct ConnectionsLoadingView: View {
    /// When the wait began. Owned by the caller so it survives the parent's re-renders.
    let startedAt: Date

    private static let slowThreshold: TimeInterval = 5
    private static let verySlowThreshold: TimeInterval = 12

    private func message(at now: Date) -> String {
        switch now.timeIntervalSince(startedAt) {
        case ..<Self.slowThreshold: "Loading live departures…"
        case ..<Self.verySlowThreshold: "Still loading. ÖBB is slow to answer."
        default: "ÖBB is taking longer than usual."
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // TimelineView drives the elapsed-time copy without any view state to lose.
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let text = message(at: context.date)
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .animation(.easeInOut(duration: 0.25), value: text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(text)
            }

            SkeletonLoadingView(count: 3)
        }
    }
}

// MARK: - SkeletonLoadingView

struct SkeletonLoadingView: View {
    let count: Int
    var body: some View { VStack(spacing: 12) { ForEach(0 ..< count, id: \.self) { _ in SkeletonConnectionCard() } } }
}

// MARK: - SkeletonConnectionCard

struct SkeletonConnectionCard: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        skeletonContent
            .skeletonShimmer()
            .background(skeletonBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(skeletonBorder)
    }

    private var skeletonContent: some View {
        VStack(spacing: 0) {
            skeletonHeader
            Divider().padding(.horizontal, 16)
            skeletonTimeInfo
            skeletonFooter
        }
    }

    private var skeletonHeader: some View {
        HStack(spacing: 12) {
            SkeletonBox(width: 50, height: 36, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBox(width: 120, height: 14)
                SkeletonBox(width: 80, height: 10)
            }
            Spacer()
        }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private var skeletonTimeInfo: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBox(width: 50, height: 10)
                SkeletonBox(width: 70, height: 24)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                SkeletonBox(width: 50, height: 10)
                SkeletonBox(width: 70, height: 24)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var skeletonFooter: some View {
        HStack(spacing: 16) {
            SkeletonBox(width: 56, height: 56, cornerRadius: 28)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBox(width: 60, height: 10)
                SkeletonBox(width: 80, height: 18)
            }
            Spacer()
            SkeletonBox(width: 44, height: 44, cornerRadius: 22)
        }.padding(16).background(Color.gray.opacity(colorScheme == .dark ? 0.1 : 0.05))
    }

    private var skeletonBackgroundColor: Color {
        Color.cardSurface(colorScheme)
    }

    private var skeletonBorder: some View {
        let strokeColor = colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.15)
        return RoundedRectangle(cornerRadius: 16).stroke(strokeColor, lineWidth: 1)
    }
}

// MARK: - ToastView

struct ToastView: View {
    let message: String
    let type: ToastType
    @Environment(\.colorScheme) var colorScheme

    enum ToastType {
        case success, error, info
        var icon: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .error: "xmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: .green
            case .error: .red
            case .info: .blue
            }
        }
    }

    var body: some View {
        // A rounded rectangle rather than a capsule, so a message that wraps to several lines still looks right.
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: type.icon).foregroundStyle(type.color).accessibilityHidden(true)
            Text(message).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 16).padding(.vertical, 12).background(
            colorScheme == .dark ? Color(.tertiarySystemBackground) : Color(.systemBackground), in: shape
        ).overlay(shape.stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.clear, lineWidth: 1)).shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 10, y: 5
        ).accessibilityElement(children: .combine)
    }
}

// MARK: - OfflineBanner

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.subheadline.weight(.semibold))
            Text("No internet connection").font(.subheadline.weight(.medium))
            Spacer()
        }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10).background(
            Color.orange, in: RoundedRectangle(cornerRadius: 10)
        )
    }
}

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)?
    var actionTitle: String?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        VStack(spacing: 24) {
            illustration
            VStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            if let action, let actionTitle {
                Button {
                    Haptics.impact(.light)
                    action()
                } label: {
                    Text(actionTitle).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(32).onAppear { updateBreathing(reduceMotion: reduceMotion) }
            .onChange(of: reduceMotion) { _, isReduced in updateBreathing(reduceMotion: isReduced) }
    }

    private func updateBreathing(reduceMotion: Bool) {
        if reduceMotion {
            // A short finite animation replaces the running repeatForever, which stops it.
            withAnimation(reducedMotionFade) { animate = false }
        } else {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { animate = true }
        }
    }

    private var illustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.2)).frame(width: 180, height: 8).offset(
                y: 40)
            RoundedRectangle(cornerRadius: 8).fill(
                colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.15)
            ).frame(width: 120, height: 60).offset(y: 10)
            ZStack {
                Circle().fill(Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.15)).frame(
                    width: 80, height: 80
                )
                Circle().fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.08)).frame(
                    width: 110, height: 110
                ).scaleEffect(animate ? 1.1 : 1.0)
                Image(systemName: icon).font(.system(size: 36)).foregroundStyle(Color.accentColor).offset(
                    x: animate ? 2 : -2)
            }.offset(y: -20)
        }.frame(height: 120).accessibilityHidden(true)
    }
}

// MARK: - ErrorView

struct ErrorView: View {
    let error: GleisError
    let onRetry: () -> Void
    @Environment(\.colorScheme) var colorScheme

    private var errorInfo: (icon: String, color: Color) {
        switch error {
        case .networkError, .offline, .timeout: ("wifi.slash", .orange)
        case .noRouteConfigured: ("map", .blue)
        case .apiError: ("server.rack", .red)
        default: ("exclamationmark.triangle.fill", .orange)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(errorInfo.color.opacity(colorScheme == .dark ? 0.2 : 0.1)).frame(width: 100, height: 100)
                Circle().stroke(errorInfo.color.opacity(0.3), lineWidth: 2).frame(width: 120, height: 120)
                Image(systemName: errorInfo.icon).font(.system(size: 40)).foregroundStyle(errorInfo.color)
            }
            VStack(spacing: 8) {
                Text(error.userFacingTitle).font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(error.userFacingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Haptics.notification(.warning)
                onRetry()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }.buttonStyle(.borderedProminent)
        }.padding(32)
    }
}

// MARK: - RouteHeader

struct RouteHeader: View {
    let startStation: Station?
    let endStation: Station?
    let travelTimeToStart: Int?
    let bufferTimeToStart: Int?
    let onSwap: () -> Void
    let onStartTap: () -> Void
    let onEndTap: () -> Void
    let onSetTravelTime: (Station) -> Void
    let onSetBufferTime: (Station) -> Void
    var swapIcon = "arrow.left.arrow.right"
    var showsTimingControls = true
    var swapAccessibilityLabel = "Swap stations"
    var swapAccessibilityValue: String? = nil
    var departureAnchor: Date? = nil
    var onDepartureChipTap: (() -> Void)? = nil
    var onClearDepartureAnchor: (() -> Void)? = nil
    private let swapRotationStep: Double = 180
    private let swapAnimation: Animation = .spring(response: 0.3)
    private static let defaultSwapIcon = "arrow.left.arrow.right"
    private static let stackedSwapIcon = "arrow.up.arrow.down"
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var swapButtonSize: CGFloat = 36
    @State private var swapRotation: Double = 0
    @State private var pulseHint = false

    var body: some View {
        VStack(spacing: 16) {
            stationRow
            timingRow
        }.padding(16).background(colorScheme == .dark ? Color(.secondarySystemBackground) : .white).clipShape(
            RoundedRectangle(cornerRadius: 20)
        ).overlay(
            RoundedRectangle(cornerRadius: 20).stroke(
                colorScheme == .dark ? Color.white.opacity(0.1) : Color.clear, lineWidth: 1
            )
        ).shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 8, y: 4)
            .onAppear { updateHintPulse(reduceMotion: reduceMotion) }
            .onChange(of: reduceMotion) { _, isReduced in updateHintPulse(reduceMotion: isReduced) }
    }

    /// Side by side normally; stacked at accessibility sizes so both station names keep their full width.
    @ViewBuilder private var stationRow: some View {
        let fromButton = StationButton(label: "From", station: startStation, icon: "location.circle.fill", color: .green) {
            Haptics.selection()
            onStartTap()
        }
        let toButton = StationButton(label: "To", station: endStation, icon: "flag.circle.fill", color: .red) {
            Haptics.selection()
            onEndTap()
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                fromButton
                swapButton
                toButton
            }
        } else {
            HStack(spacing: 12) {
                fromButton.layoutPriority(1)
                swapButton
                toButton.layoutPriority(1)
            }
        }
    }

    private var timingRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                timingControls
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) { timingControls }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var timingControls: some View {
        if showsTimingControls, let station = startStation {
            if let time = travelTimeToStart {
                Button {
                    onSetTravelTime(station)
                } label: {
                    Label("\(time) min", systemImage: "figure.walk").font(.caption).foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            } else {
                travelTimeHintButton(for: station)
            }
            if let buffer = bufferTimeToStart {
                Button {
                    onSetBufferTime(station)
                } label: {
                    Label("\(buffer) min buffer", systemImage: "clock.badge.checkmark").font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else {
                bufferTimeHintButton(for: station)
            }
        }
        if showsTimingControls, let onDepartureChipTap {
            departureChip(onTap: onDepartureChipTap)
        }
    }

    private func departureChip(onTap: @escaping () -> Void) -> some View {
        let isAnchored = departureAnchor != nil
        let title = Self.departureChipTitle(for: departureAnchor)
        return HStack(spacing: 6) {
            Button(action: onTap) {
                Label(title, systemImage: "clock").font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Departure time, \(title)")
            .accessibilityHint("Choose when to look for trains")
            if isAnchored, let onClearDepartureAnchor {
                Button(action: onClearDepartureAnchor) {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to now")
            }
        }
        .foregroundStyle(isAnchored ? Color.white : Color.accentColor)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isAnchored ? Color.accentColor : Color.accentColor.opacity(0.12), in: Capsule())
    }

    /// "Now", "Today 17:30", "Tomorrow 07:00", or the weekday for anything later.
    static func departureChipTitle(for anchor: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let anchor else { return "Now" }
        let time = anchor.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(anchor, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(anchor, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        return anchor.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private func updateHintPulse(reduceMotion: Bool) {
        if reduceMotion {
            withAnimation(reducedMotionFade) { pulseHint = false }
        } else {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulseHint = true }
        }
    }

    @ViewBuilder
    private var swapButton: some View {
        let isStacked = dynamicTypeSize.isAccessibilitySize && swapIcon == Self.defaultSwapIcon
        let button = Button {
            Haptics.impact(.light)
            withAnimation(reduceMotion ? nil : swapAnimation) { swapRotation += swapRotationStep }
            onSwap()
        } label: {
            Image(systemName: isStacked ? Self.stackedSwapIcon : swapIcon).font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: swapButtonSize, height: swapButtonSize).background(Color.accentColor, in: Circle())
                .rotationEffect(.degrees(swapRotation))
        }.buttonStyle(.plain).accessibilityLabel(swapAccessibilityLabel)

        if let swapAccessibilityValue {
            button.accessibilityValue(swapAccessibilityValue)
        } else {
            button
        }
    }

    private func travelTimeHintButton(for station: Station) -> some View {
        Button {
            onSetTravelTime(station)
        } label: {
            Label("Set Time to Station", systemImage: "plus.circle.fill").font(.caption).foregroundStyle(.blue).opacity(
                pulseHint ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }

    private func bufferTimeHintButton(for station: Station) -> some View {
        Button {
            onSetBufferTime(station)
        } label: {
            Label("Set Buffer", systemImage: "plus.circle.fill").font(.caption).foregroundStyle(.orange).opacity(
                pulseHint ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - StationButton

struct StationButton: View {
    let label: String
    let station: Station?
    let icon: String
    let color: Color
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var showFullName = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(label).foregroundStyle(.secondary)
                }.font(.caption)
                // Wraps rather than truncates, so a long station name is always readable in full.
                Text(station?.name ?? "Pick a Station").font(.subheadline.weight(.medium)).foregroundStyle(
                    station == nil ? .secondary : .primary
                ).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(12).background(
                colorScheme == .dark ? Color.white.opacity(0.08) : Color.gray.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 12)
            ).accessibilityLabel("\(label) station: \(station?.name ?? "Not selected")")
        }.buttonStyle(.plain).onLongPressGesture(minimumDuration: 0.5) {
            guard station != nil else { return }
            Haptics.impact(.light)
            showFullName = true
        }.popover(isPresented: $showFullName, arrowEdge: .bottom) {
            Text(station?.name ?? "").font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 12)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - BottomScrollSentinel

/// Detects when the user reaches the bottom region of the list to trigger pagination.
/// Fires once per load cycle and retriggers after loading completes.
struct BottomScrollSentinel: View {
    let onScrollPastEnd: () -> Void
    let isLoading: Bool

    @State private var hasTriggered = false
    @State private var lastMinY: CGFloat = .greatestFiniteMagnitude

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    lastMinY = proxy.frame(in: .global).minY
                    guard !isLoading, !hasTriggered else { return }
                    let triggerThreshold = UIScreen.main.bounds.height + 24
                    if lastMinY < triggerThreshold {
                        hasTriggered = true
                        onScrollPastEnd()
                    }
                }
                .onChange(of: proxy.frame(in: .global).minY) { _, minY in
                    lastMinY = minY
                    guard !isLoading, !hasTriggered else { return }
                    // Trigger as soon as sentinel enters the viewport near the bottom.
                    let triggerThreshold = UIScreen.main.bounds.height + 24
                    if minY < triggerThreshold {
                        hasTriggered = true
                        onScrollPastEnd()
                    }
                }
        }
        .frame(height: 60)
        .onChange(of: isLoading) { wasLoading, nowLoading in
            // Reset trigger state when loading completes so user can trigger again.
            if wasLoading, !nowLoading {
                hasTriggered = false
                let triggerThreshold = UIScreen.main.bounds.height + 24
                if lastMinY < triggerThreshold {
                    hasTriggered = true
                    onScrollPastEnd()
                }
            }
        }
    }
}

// MARK: - TrainTypeFilterBar

struct TrainTypeFilterBar: View {
    let availableTypes: [TrainType]
    @Binding var excludedTypes: Set<TrainType>
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableTypes) { type in
                    let isEnabled = !excludedTypes.contains(type)
                    let style = Color.lineBadgeStyle(for: type.shortName, apiColors: type.colors)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isEnabled {
                                excludedTypes.insert(type)
                            } else {
                                excludedTypes.remove(type)
                            }
                        }
                    } label: {
                        Text(type.shortName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isEnabled
                                    ? style.background
                                    : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.15)),
                                in: Capsule()
                            )
                            .foregroundStyle(isEnabled ? style.foreground : .secondary)
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(isEnabled ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - EndOfListFooter

struct EndOfListFooter: View {
    let count: Int

    var body: some View {
        VStack(spacing: 6) {
            Capsule().frame(width: 40, height: 4).foregroundStyle(.quaternary)
            Text(count == 1 ? "Showing 1 connection" : "Showing \(count) connections").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}
