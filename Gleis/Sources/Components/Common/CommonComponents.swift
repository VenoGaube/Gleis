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
    @Namespace private var tabAnimation

    var body: some View {
        HStack(spacing: 0) { ForEach(tabs) { tab in tabButton(for: tab) } }.padding(.horizontal, 16).padding(.top, 16)
            .padding(.bottom, 16).background(
                Rectangle().fill(colorScheme == .dark ? Color(.systemBackground) : .white).shadow(
                    color: .black.opacity(0.08), radius: 12, y: -4
                ).ignoresSafeArea(edges: .bottom))
    }

    private func tabButton(for tab: TabItem) -> some View {
        let isSelected = selectedTab == tab.id

        return Button {
            Haptics.impact(.light)
            onTabTap?(tab.id)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { selectedTab = tab.id }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    // Background pill
                    if isSelected {
                        Capsule().fill(accentColor).frame(width: 56, height: 32).matchedGeometryEffect(
                            id: "tabPill", in: tabAnimation
                        ).shadow(color: accentColor.opacity(0.4), radius: 8, y: 2)
                    }

                    Image(systemName: isSelected ? tab.selectedIcon : tab.icon).font(
                        .system(size: 18, weight: .semibold)
                    ).foregroundStyle(isSelected ? .white : .secondary).scaleEffect(isSelected ? 1.0 : 0.9).animation(
                        .spring(response: 0.25, dampingFraction: 0.7), value: isSelected
                    )
                }.frame(height: 32)

                Text(tab.title).font(.caption).fontWeight(isSelected ? .semibold : .medium).foregroundStyle(
                    isSelected ? accentColor : .secondary)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(TabButtonStyle())
    }
}

// MARK: - TabButtonStyle

struct TabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1.0).opacity(
            configuration.isPressed ? 0.85 : 1.0
        ).animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Haptics

enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - SkeletonBox

struct SkeletonBox: View {
    var width: CGFloat?
    var height: CGFloat = 16
    var cornerRadius: CGFloat = 4
    @State private var shimmer = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.2)).frame(
            width: width, height: height
        ).overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing
                ).frame(width: geo.size.width * 0.6).offset(x: shimmer ? geo.size.width : -geo.size.width * 0.6)
            }.mask(RoundedRectangle(cornerRadius: cornerRadius))
        ).onAppear { withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { shimmer = true } }
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
        colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground)
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
        HStack(spacing: 10) {
            Image(systemName: type.icon).foregroundStyle(type.color)
            Text(message).font(.subheadline.weight(.medium))
        }.padding(.horizontal, 16).padding(.vertical, 12).background(
            colorScheme == .dark ? Color(.tertiarySystemBackground) : Color(.systemBackground), in: Capsule()
        ).overlay(Capsule().stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.clear, lineWidth: 1)).shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 10, y: 5
        )
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

// MARK: - CachedDataBanner

struct CachedDataBanner: View {
    let lastUpdated: Date?

    private var timeAgoText: String {
        guard let lastUpdated else { return "" }
        let minutes = Int(Date().timeIntervalSince(lastUpdated) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h ago" : "over a day ago"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing cached data").font(.subheadline.weight(.medium))
                if lastUpdated != nil { Text("Updated \(timeAgoText)").font(.caption).opacity(0.9) }
            }
            Spacer()
            Text("Pull to refresh").font(.caption).opacity(0.8)
        }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10).background(
            Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 10)
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
    @State private var animate = false

    var body: some View {
        VStack(spacing: 24) {
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
            }.frame(height: 120)
            VStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let action, let actionTitle {
                Button {
                    Haptics.impact(.light)
                    action()
                } label: {
                    Text(actionTitle).font(.subheadline.weight(.semibold)).padding(.horizontal, 24).padding(
                        .vertical, 12
                    )
                }.buttonStyle(.borderedProminent)
            }
        }.padding(32).onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { animate = true }
        }
    }
}

// MARK: - ErrorView

struct ErrorView: View {
    let error: GleisError
    let onRetry: () -> Void
    @Environment(\.colorScheme) var colorScheme

    private var errorInfo: (icon: String, color: Color) {
        switch error {
        case .networkError: ("wifi.slash", .orange)
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
                Text(error.errorDescription ?? "Something went wrong").font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
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
    let transportType: TransportType
    let startStation: Station?
    let endStation: Station?
    let travelTimeToStart: Int?
    let travelTimeToEnd: Int?
    let suggestedTravelTimeToStart: Int?
    let suggestedTravelTimeToEnd: Int?
    let bufferTimeToStart: Int?
    let bufferTimeToEnd: Int?
    let onSwap: () -> Void
    let isAutoSelectionEnabled: Bool
    let autoSelectionStatusMessage: String?
    let onToggleAutoSelection: () -> Void
    let onStartTap: () -> Void
    let onEndTap: () -> Void
    let onSetTravelTime: (Station) -> Void
    let onSetBufferTime: (Station) -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var swapRotation: Double = 0
    @State private var pulseHint = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                StationButton(
                    label: "From", station: startStation, icon: "location.circle.fill", color: .green
                ) {
                    Haptics.selection()
                    onStartTap()
                }.layoutPriority(1)
                Button {
                    Haptics.impact(.light)
                    withAnimation(.spring(response: 0.3)) { swapRotation += 180 }
                    onSwap()
                } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Color.accentColor, in: Circle()).rotationEffect(
                            .degrees(swapRotation))
                }.buttonStyle(.plain)
                StationButton(
                    label: "To", station: endStation, icon: "flag.circle.fill", color: .red
                ) {
                    Haptics.selection()
                    onEndTap()
                }.layoutPriority(1)
            }
            HStack(spacing: 12) {
                if let station = startStation {
                    if let time = travelTimeToStart {
                        Button {
                            onSetTravelTime(station)
                        } label: {
                            Label("\(time) min", systemImage: "figure.walk").font(.caption).foregroundStyle(.blue)
                        }
                    } else if let suggested = suggestedTravelTimeToStart {
                        suggestedTravelTimeHintButton(for: station, suggested: suggested)
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
                    } else {
                        bufferTimeHintButton(for: station)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        Haptics.selection()
                        onToggleAutoSelection()
                    } label: {
                        Label(isAutoSelectionEnabled ? "Auto On" : "Auto Off", systemImage: autoIndicatorIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isAutoSelectionEnabled ? .green : .orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                (isAutoSelectionEnabled ? Color.green : Color.orange).opacity(colorScheme == .dark ? 0.18 : 0.12),
                                in: Capsule()
                            )
                    }.buttonStyle(.plain)

                    if let autoSelectionStatusMessage {
                        Text(autoSelectionStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
        }.padding(16).background(colorScheme == .dark ? Color(.secondarySystemBackground) : .white).clipShape(
            RoundedRectangle(cornerRadius: 20)
        ).overlay(
            RoundedRectangle(cornerRadius: 20).stroke(
                colorScheme == .dark ? Color.white.opacity(0.1) : Color.clear, lineWidth: 1
            )
        ).shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 8, y: 4).onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulseHint = true }
        }
    }

    private var autoIndicatorIcon: String {
        isAutoSelectionEnabled ? "location.fill" : "location.slash.fill"
    }

    private func travelTimeHintButton(for station: Station) -> some View {
        Button {
            onSetTravelTime(station)
        } label: {
            Label("Set travel time", systemImage: "plus.circle.fill").font(.caption).foregroundStyle(.blue).opacity(
                pulseHint ? 0.6 : 1)
        }
    }

    private func suggestedTravelTimeHintButton(for station: Station, suggested: Int) -> some View {
        Button {
            onSetTravelTime(station)
        } label: {
            Label("Suggested \(suggested) min", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.blue)
                .opacity(pulseHint ? 0.7 : 1)
        }
    }

    private func bufferTimeHintButton(for station: Station) -> some View {
        Button {
            onSetBufferTime(station)
        } label: {
            Label("Set buffer", systemImage: "plus.circle.fill").font(.caption).foregroundStyle(.orange).opacity(
                pulseHint ? 0.6 : 1)
        }
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
                Text(station?.name ?? "Select").font(.subheadline.weight(.medium)).foregroundStyle(
                    station == nil ? .secondary : .primary
                ).lineLimit(1).truncationMode(.tail)
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
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - BottomScrollSentinel

/// Detects when user scrolls past the end of content (overscroll) to trigger pagination.
/// Only fires when the sentinel is pulled significantly into view, not just when it appears.
struct BottomScrollSentinel: View {
    let onScrollPastEnd: () -> Void
    let isLoading: Bool

    @State private var hasTriggered = false

    var body: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global).minY) { _, minY in
                guard !isLoading, !hasTriggered else { return }
                let screenHeight = UIScreen.main.bounds.height
                // Trigger when sentinel top is pulled above 85% of screen height
                // This means user has scrolled past the content end
                let triggerThreshold = screenHeight * 0.85
                if minY < triggerThreshold {
                    hasTriggered = true
                    onScrollPastEnd()
                }
            }
        }.frame(height: 60).onChange(of: isLoading) { wasLoading, nowLoading in
            // Reset trigger state when loading completes so user can trigger again
            if wasLoading, !nowLoading { hasTriggered = false }
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
                            .overlay {
                                if isEnabled, let border = style.border {
                                    Capsule().stroke(border.opacity(0.7), lineWidth: 1)
                                }
                            }
                    }.buttonStyle(.plain)
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
            Text("Showing \(count) connections").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

// MARK: - TravelTimeSheet

struct TravelTimeSheet: View {
    let station: Station
    let currentValue: Int?
    let suggestedValue: Int?
    let onSave: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 10

    init(station: Station, currentValue: Int? = nil, suggestedValue: Int? = nil, onSave: @escaping (Int?) -> Void) {
        self.station = station
        self.currentValue = currentValue
        self.suggestedValue = suggestedValue
        self.onSave = onSave
        _minutes = State(initialValue: currentValue ?? suggestedValue ?? 10)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let suggestedValue {
                    Section("Suggested") {
                        HStack {
                            Label("\(suggestedValue) min from current location", systemImage: "sparkles")
                            Spacer()
                            Button("Use") { minutes = suggestedValue }
                        }
                    }
                }
                Section {
                    Stepper(value: $minutes, in: 1 ... 60) {
                        HStack {
                            Image(systemName: "figure.walk").foregroundStyle(.blue)
                            Text("\(minutes) min")
                        }
                    }
                } header: {
                    Text("Travel time to \(station.name)")
                } footer: {
                    Text("How long it takes you to reach this station from home/work.")
                }
            }.navigationTitle("Travel Time").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(minutes)
                        dismiss()
                    }
                }
            }
        }.presentationDetents([suggestedValue == nil ? .height(220) : .height(280)])
    }
}

// MARK: - BufferTimeSheet

struct BufferTimeSheet: View {
    let station: Station
    let currentValue: Int?
    let onSave: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 2

    init(station: Station, currentValue: Int? = nil, onSave: @escaping (Int?) -> Void) {
        self.station = station
        self.currentValue = currentValue
        self.onSave = onSave
        _minutes = State(initialValue: currentValue ?? 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minutes, in: 0 ... 30) {
                        HStack {
                            Image(systemName: "clock.badge.checkmark").foregroundStyle(.orange)
                            Text("\(minutes) min")
                        }
                    }
                } header: {
                    Text("Buffer time for \(station.name)")
                } footer: {
                    Text("Extra time before departure to account for delays, queues, or finding your platform.")
                }
            }.navigationTitle("Buffer Time").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(minutes)
                        dismiss()
                    }
                }
            }
        }.presentationDetents([.height(220)])
    }
}
