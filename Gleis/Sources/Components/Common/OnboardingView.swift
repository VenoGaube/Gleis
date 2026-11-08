import SwiftUI
import UserNotifications
import UIKit

// MARK: - OnboardingView

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @StateObject private var settingsManager = SettingsManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var currentStepIndex = 0
    @State private var originStation: Station?
    @State private var destinationStation: Station?
    @State private var pinnedJourney: TrainConnection?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isRequestingNotificationPermission = false

    private let steps = OnboardingStep.allCases
    private let stepBottomPadding: CGFloat = 4
    /// Room under the card at accessibility sizes so its last line and shadow (radius 12, y 6) scroll clear of the page's clip edge.
    private let accessibilityScrollEndMargin: CGFloat = 20

    private var isLastStep: Bool { currentStepIndex == steps.count - 1 }
    private var hasPersistedRouteConfiguration: Bool {
        guard
            let start = settingsManager.trainCommuteConfig.startStation,
            let end = settingsManager.trainCommuteConfig.endStation
        else { return false }
        return start.id != end.id
    }
    private var hasOnboardingRouteSelection: Bool {
        guard let start = originStation, let end = destinationStation else { return false }
        return start.id != end.id
    }
    private var isJourneyConfigured: Bool { hasOnboardingRouteSelection || hasPersistedRouteConfiguration }
    private var isNotificationEnabled: Bool {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        default:
            false
        }
    }

    private var canContinue: Bool {
        guard let step = steps[safe: currentStepIndex] else { return false }
        return !step.requiresPinnedJourney || pinnedJourney != nil
    }

    var body: some View {
        VStack(spacing: 20) {
            topBar

            TabView(selection: $currentStepIndex) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    GeometryReader { page in
                        ScrollView(.vertical, showsIndicators: dynamicTypeSize.isAccessibilitySize) {
                            stepView(step)
                                .environment(\.onboardingPanelMinHeight, max(0, page.size.height - stepBottomPadding))
                                .padding(.horizontal, 20)
                                .padding(.bottom, stepBottomPadding)
                        }
                        .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? accessibilityScrollEndMargin : 0, for: .scrollContent)
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicatorsFlash(onAppear: true)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: currentStepIndex)

            footer
        }
        .padding(.top, 8)
        .padding(.bottom, 24)
        // As a ZStack sibling the 420pt glow made the stack 420pt wide and the content was placed at that width, past a 375pt screen; a background takes the content's size instead.
        .background { OnboardingBackdrop() }
        .task { await refreshNotificationStatus() }
        .onChange(of: currentStepIndex) { _, newIndex in
            if steps[safe: newIndex] == .timing { persistSetupSelections() }
            Task { await refreshNotificationStatus() }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task { await refreshNotificationStatus() }
        }
        .onDisappear {
            currentStepIndex = 0
            originStation = nil
            destinationStation = nil
            pinnedJourney = nil
        }
    }

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                backButton
                Spacer()
                stepCounter
                Spacer()
                skipButton
            }
            VStack(spacing: 8) {
                HStack {
                    backButton
                    Spacer(minLength: 8)
                    skipButton
                }
                stepCounter
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var backButton: some View {
        if currentStepIndex > 0 {
            Button {
                withAnimation { currentStepIndex -= 1 }
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(OnboardingSecondaryButtonStyle())
        } else {
            // Holds the Back button's place so the counter stays centred on the first step.
            Color.clear.frame(width: 88, height: 36)
        }
    }

    private var stepCounter: some View {
        Text("\(currentStepIndex + 1) / \(steps.count)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemBackground), in: Capsule())
            .accessibilityLabel("Step \(currentStepIndex + 1) of \(steps.count)")
    }

    private var skipButton: some View {
        Button("Skip") { completeOnboarding() }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(OnboardingSecondaryButtonStyle())
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0 ..< steps.count, id: \.self) { index in
                    Capsule()
                        .fill(index == currentStepIndex ? Color.trainBlue : Color.gray.opacity(0.3))
                        .frame(width: index == currentStepIndex ? 28 : 10, height: 8)
                        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: currentStepIndex)
                }
            }

            Button {
                if isLastStep {
                    completeOnboarding()
                } else {
                    withAnimation { currentStepIndex += 1 }
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(isLastStep ? "Get Started" : "Continue")
                        Image(systemName: isLastStep ? "checkmark.circle.fill" : "arrow.right")
                    }
                    Text(isLastStep ? "Get Started" : "Continue")
                        .multilineTextAlignment(.center)
                }
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!canContinue)
            .opacity(canContinue ? 1 : 0.5)
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private func stepView(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            WelcomeStepView(
                step: step,
                isJourneyConfigured: isJourneyConfigured,
                isNotificationEnabled: isNotificationEnabled,
                isRequestingNotificationPermission: isRequestingNotificationPermission,
                onOpenSetup: { withAnimation { currentStepIndex = 1 } },
                onEnableNotifications: { Task { await requestNotificationPermission() } }
            )
        case .journey:
            JourneySetupStepView(
                step: step,
                originStation: $originStation,
                destinationStation: $destinationStation,
                pinnedJourney: $pinnedJourney
            )
        case .timing:
            TimingSetupStepView(step: step, originStation: originStation ?? settingsManager.trainCommuteConfig.startStation)
        case .widget:
            WidgetStepView(step: step, pinnedJourney: pinnedJourney)
        case .notifications:
            NotificationStepView(
                step: step,
                pinnedJourney: pinnedJourney,
                notificationStatus: notificationStatus,
                isRequestingPermission: isRequestingNotificationPermission,
                onRequestPermission: { Task { await requestNotificationPermission() } }
            )
        }
    }

    private func completeOnboarding() {
        persistSetupSelections()
        isPresented = false
    }

    private func persistSetupSelections() {
        var config = settingsManager.trainCommuteConfig

        if let originStation {
            config.startStation = originStation
            config.addRecentStation(originStation)
        }

        if let destinationStation {
            config.endStation = destinationStation
            config.addRecentStation(destinationStation)
        }

        settingsManager.updateConfig(config)
    }

    private func refreshNotificationStatus() async {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    notificationStatus = settings.authorizationStatus
                    continuation.resume()
                }
            }
        }
    }

    private func requestNotificationPermission() async {
        isRequestingNotificationPermission = true
        defer { isRequestingNotificationPermission = false }

        do {
            let granted = try await NotificationService.shared.requestAuthorization()
            notificationStatus = granted ? .authorized : .denied
        } catch {
            notificationStatus = .denied
        }
    }
}

// MARK: - OnboardingStep

enum OnboardingStep: CaseIterable {
    case welcome
    case journey
    case timing
    case widget
    case notifications

    var eyebrow: String {
        switch self {
        case .welcome: "WELCOME"
        case .journey: "SETUP"
        case .timing: "TIMING"
        case .widget: "WIDGET"
        case .notifications: "REMINDERS"
        }
    }

    var title: String {
        switch self {
        case .welcome: "Your Trains, Live"
        case .journey: "Pick Your Daily Route"
        case .timing: "Time to Station"
        case .widget: "See It on Your Home Screen"
        case .notifications: "Know When to Leave"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "This is how My Journey and your connections look in the Train tab."
        case .journey: "Pick your start and destination stations to see your connections."
        case .timing: "Gleis takes this off each departure time to tell you when to leave. Without it, your leave time is the departure time."
        case .widget: "Add the widget to your Home Screen to see your next train, when to leave and the platform."
        case .notifications: "Allow reminders so Gleis can tell you when to leave."
        }
    }

    var requiresPinnedJourney: Bool { false }
}

// MARK: - TimingSetupStepView

/// Collects walking and buffer time during setup.
///
/// These default to zero, and nothing in the app used to ask for them, so a new
/// user's "leave at" time was identical to the departure time, quietly making the
/// app's core number useless until they discovered the per-station sheets.
struct TimingSetupStepView: View {
    let step: OnboardingStep
    let originStation: Station?

    @StateObject private var settingsManager = SettingsManager.shared

    private var walkingMinutes: Int {
        settingsManager.trainCommuteConfig.travelTime(for: originStation?.id)
            ?? settingsManager.trainCommuteConfig.walkingTimeMinutes
    }

    private var bufferMinutes: Int {
        settingsManager.trainCommuteConfig.bufferTime(for: originStation?.id)
            ?? settingsManager.trainCommuteConfig.bufferTimeMinutes
    }

    private var totalLeadMinutes: Int { walkingMinutes + bufferMinutes }

    var body: some View {
        OnboardingPanel(step: step) {
            VStack(spacing: 14) {
                OnboardingTimingStepper(
                    title: "Time to station",
                    subtitle: originStation.map { "From home to \($0.name)" } ?? "From home to the station",
                    systemImage: "figure.walk",
                    tint: .trainBlue,
                    minutes: walkingMinutes,
                    range: 0 ... 90,
                    onChange: updateWalking
                )

                OnboardingTimingStepper(
                    title: "Buffer",
                    subtitle: "Extra minutes so you don't have to rush",
                    systemImage: "hourglass",
                    tint: .orange,
                    minutes: bufferMinutes,
                    range: 0 ... 30,
                    onChange: updateBuffer
                )

                summaryCard
            }
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 6) {
            if totalLeadMinutes == 0 {
                Text("Your leave time is the departure time")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Set your time to station so Gleis can tell you when to leave.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Leave \(totalLeadMinutes) min before departure")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("You can change this for each station later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// Writes both the route-wide default and the origin override, so the value
    /// applies immediately and survives a later change of starting station.
    private func updateWalking(_ minutes: Int) {
        var config = settingsManager.trainCommuteConfig
        config.walkingTimeMinutes = minutes
        if let id = originStation?.id { config.setTravelTime(minutes, for: id) }
        settingsManager.updateConfig(config)
    }

    private func updateBuffer(_ minutes: Int) {
        var config = settingsManager.trainCommuteConfig
        config.bufferTimeMinutes = minutes
        if let id = originStation?.id { config.setBufferTime(minutes, for: id) }
        settingsManager.updateConfig(config)
    }
}

// MARK: - OnboardingTimingStepper

struct OnboardingTimingStepper: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let minutes: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    private let quickPicks = [0, 5, 10, 15]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var iconTileSize: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stacked at accessibility sizes so the station name in the subtitle keeps a full line.
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    iconTile
                    Spacer(minLength: 8)
                    minutesText
                }
                titles
            } else {
                HStack(spacing: 12) {
                    iconTile
                    titles
                    Spacer(minLength: 8)
                    minutesText
                }
            }

            Stepper(
                value: Binding(get: { minutes }, set: onChange),
                in: range,
                step: 1
            ) {
                EmptyView()
            }
            .labelsHidden()

            HStack(spacing: 8) {
                ForEach(quickPicks.filter { range.contains($0) }, id: \.self) { value in
                    Button {
                        Haptics.selection()
                        onChange(value)
                    } label: {
                        Text("\(value)")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(minutes == value ? tint.opacity(0.22) : Color.primary.opacity(0.06))
                            )
                            .foregroundStyle(minutes == value ? tint : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var iconTile: some View {
        Image(systemName: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
            .frame(width: iconTileSize, height: iconTileSize)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var minutesText: some View {
        Text("\(minutes) min")
            .font(.headline.monospacedDigit())
            .foregroundStyle(tint)
    }
}

// MARK: - WelcomeStepView

struct WelcomeStepView: View {
    let step: OnboardingStep
    let isJourneyConfigured: Bool
    let isNotificationEnabled: Bool
    let isRequestingNotificationPermission: Bool
    let onOpenSetup: () -> Void
    let onEnableNotifications: () -> Void

    var body: some View {
        OnboardingPanel(step: step) {
            VStack(spacing: 14) {
                ExactTrainViewPreviewCard()
                SetupChecklistCard(
                    isJourneyConfigured: isJourneyConfigured,
                    isNotificationEnabled: isNotificationEnabled,
                    isRequestingNotificationPermission: isRequestingNotificationPermission,
                    onOpenSetup: onOpenSetup,
                    onEnableNotifications: onEnableNotifications
                )
            }
        }
    }
}

struct ExactTrainViewPreviewCard: View {
    @StateObject private var settingsManager = SettingsManager.shared

    private var previewOrigin: Station {
        settingsManager.trainCommuteConfig.startStation
            ?? Station(id: "onboarding-origin", name: "Wien Mitte", coordinate: nil)
    }

    private var previewDestination: Station {
        settingsManager.trainCommuteConfig.endStation
            ?? Station(id: "onboarding-destination", name: "Flughafen Wien", coordinate: nil)
    }

    private var reusablePinnedJourney: PinnedJourney? {
        guard let journey = settingsManager.pinnedJourney, !journey.shouldAutoUnpin() else { return nil }
        return journey
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    previewTitle
                    Spacer()
                    previewTag
                }
                VStack(alignment: .leading, spacing: 4) {
                    previewTitle
                    previewTag
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let referenceDate = context.date
                let samplePinnedJourney = makeSamplePinnedJourney(referenceDate: referenceDate)
                let previewPinnedJourney = reusablePinnedJourney ?? samplePinnedJourney
                let displayConnections = makeSampleDisplayConnections(referenceDate: referenceDate)

                OnboardingCardListScroll(height: 360, showsIndicators: false) {
                    VStack(spacing: 10) {
                        MyJourneyCard(journey: previewPinnedJourney) {}
                            .allowsHitTesting(false)

                        ForEach(displayConnections) { displayConnection in
                            ConnectionCard(
                                displayConnection: displayConnection,
                                onSchedule: {},
                                onCancel: {},
                                onPin: {},
                                onUnpin: {},
                                onTap: {}
                            )
                            .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        )
    }

    private var previewTitle: some View {
        Label("Same as the Train tab", systemImage: "rectangle.stack.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color(red: 0.11, green: 0.29, blue: 0.53))
    }

    private var previewTag: some View {
        Text("Live preview")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func makeSamplePinnedJourney(referenceDate: Date) -> PinnedJourney {
        let departureTime = referenceDate.addingTimeInterval(6 * 60)
        let arrivalTime = departureTime.addingTimeInterval(19 * 60)
        let connection = TrainConnection(
            id: "onboarding-my-journey",
            lineNumber: "S7",
            trainType: .s,
            lineColors: nil,
            departureTime: departureTime,
            arrivalTime: arrivalTime,
            departureStation: previewOrigin,
            arrivalStation: previewDestination,
            platform: "3",
            delay: 0,
            status: .onTime,
            transfers: 0,
            legs: []
        )
        return PinnedJourney(from: connection)
    }

    private func makeSampleDisplayConnections(referenceDate: Date) -> [DisplayConnection] {
        let config = settingsManager.trainCommuteConfig

        let firstDeparture = referenceDate.addingTimeInterval(11 * 60)
        let secondDeparture = referenceDate.addingTimeInterval(20 * 60)

        let firstConnection = TrainConnection(
            id: "onboarding-connection-1",
            lineNumber: "S1",
            trainType: .s,
            lineColors: nil,
            departureTime: firstDeparture,
            arrivalTime: firstDeparture.addingTimeInterval(18 * 60),
            departureStation: previewOrigin,
            arrivalStation: previewDestination,
            platform: "1",
            delay: 0,
            status: .onTime,
            transfers: 0,
            legs: []
        )
        let secondConnection = TrainConnection(
            id: "onboarding-connection-2",
            lineNumber: "REX",
            trainType: TrainType(id: "REX", shortName: "REX", displayName: "REX"),
            lineColors: nil,
            departureTime: secondDeparture,
            arrivalTime: secondDeparture.addingTimeInterval(21 * 60),
            departureStation: previewOrigin,
            arrivalStation: previewDestination,
            platform: "5",
            delay: 2,
            status: .delayed,
            transfers: 0,
            legs: []
        )

        let firstLeave = config.leaveTime(for: firstConnection, fromStationId: previewOrigin.id)
        let secondLeave = config.leaveTime(for: secondConnection, fromStationId: previewOrigin.id)

        return [
            DisplayConnection(
                connection: firstConnection,
                leaveTime: firstLeave,
                isSelected: false,
                isPinned: false,
                currentTime: referenceDate
            ),
            DisplayConnection(
                connection: secondConnection,
                leaveTime: secondLeave,
                isSelected: false,
                isPinned: false,
                currentTime: referenceDate
            ),
        ]
    }
}

struct SetupChecklistCard: View {
    let isJourneyConfigured: Bool
    let isNotificationEnabled: Bool
    let isRequestingNotificationPermission: Bool
    let onOpenSetup: () -> Void
    let onEnableNotifications: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup Checklist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            OnboardingCheckRow(
                title: "Choose your route",
                subtitle: "Pick your start and destination stations in Setup.",
                isComplete: isJourneyConfigured,
                actionTitle: isJourneyConfigured ? nil : "Open Setup",
                action: isJourneyConfigured ? nil : onOpenSetup
            )
            OnboardingCheckRow(
                title: "Enable notifications",
                subtitle: "Get a reminder when it's time to leave.",
                isComplete: isNotificationEnabled,
                actionTitle: isNotificationEnabled ? nil : (isRequestingNotificationPermission ? "Requesting..." : "Enable"),
                action: (isNotificationEnabled || isRequestingNotificationPermission) ? nil : onEnableNotifications
            )
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}

struct OnboardingCheckRow: View {
    let title: String
    let subtitle: String
    let isComplete: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(isComplete ? .green : .secondary)
                .padding(.top, 2)

            // The action button moves under the text at accessibility sizes so neither squeezes the other.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    titles
                    actionButton
                }
                Spacer(minLength: 0)
            } else {
                titles
                Spacer(minLength: 8)
                actionButton
            }
        }
        .padding(.vertical, 2)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var actionButton: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.trainBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.trainBlue.opacity(0.1), in: Capsule())
        }
    }
}

// MARK: - JourneySetupStepView

struct JourneySetupStepView: View {
    let step: OnboardingStep

    @Binding var originStation: Station?
    @Binding var destinationStation: Station?
    @Binding var pinnedJourney: TrainConnection?

    @StateObject private var settingsManager = SettingsManager.shared
    @State private var showOriginPicker = false
    @State private var showDestinationPicker = false
    @State private var popularStations: [Station] = []
    @State private var connections: [TrainConnection] = []
    @State private var isLoadingConnections = false
    @State private var usingSampleData = false
    @State private var fetchTask: Task<Void, Never>?

    private var favorites: [Station] { settingsManager.trainCommuteConfig.favoriteStations }
    private var recent: [Station] { settingsManager.trainCommuteConfig.recentStations }

    var body: some View {
        OnboardingPanel(step: step) {
            VStack(spacing: 14) {
                routePickerCard

                if usingSampleData {
                    statusRow(icon: "wifi.slash", text: "Can't reach ÖBB right now, so these are sample trains.", color: .orange)
                }

                connectionContent
            }
            .task { await loadPopularStationsIfNeeded() }
            .onChange(of: originStation?.id) { _, _ in
                if let originStation { settingsManager.addRecentStation(originStation) }
                refreshConnections()
            }
            .onChange(of: destinationStation?.id) { _, _ in
                if let destinationStation { settingsManager.addRecentStation(destinationStation) }
                refreshConnections()
            }
            .onDisappear { fetchTask?.cancel() }
            .sheet(isPresented: $showOriginPicker) {
                stationPickerSheet(title: "From", selection: $originStation)
            }
            .sheet(isPresented: $showDestinationPicker) {
                stationPickerSheet(title: "To", selection: $destinationStation)
            }
        }
    }

    private var routePickerCard: some View {
        RouteHeader(
            startStation: originStation,
            endStation: destinationStation,
            travelTimeToStart: nil,
            bufferTimeToStart: nil,
            onSwap: {
                let currentOrigin = originStation
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    originStation = destinationStation
                    destinationStation = currentOrigin
                }
            },
            onStartTap: { showOriginPicker = true },
            onEndTap: { showDestinationPicker = true },
            onSetTravelTime: { _ in },
            onSetBufferTime: { _ in },
            showsTimingControls: false
        )
    }

    @ViewBuilder private var connectionContent: some View {
        if originStation == nil || destinationStation == nil {
            emptyStateCard(
                icon: "arrow.trianglehead.branch",
                title: "Pick two stations",
                subtitle: "You'll see the same connections as in the Train tab."
            )
        } else if isLoadingConnections {
            VStack(spacing: 10) {
                ProgressView().tint(.trainBlue)
                Text("Finding connections...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if connections.isEmpty {
            emptyStateCard(
                icon: "exclamationmark.triangle",
                title: "No connections right now",
                subtitle: "Try other stations, or continue and set your route later in the Train tab."
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    icon: pinnedJourney == nil ? "square.stack.3d.down.right" : "checkmark.circle.fill",
                    text: pinnedJourney == nil
                        ? "These are your connections, as in the Train tab. Tap one to use it in the next steps."
                        : "Used in the next steps. This doesn't pin it as My Journey.",
                    color: pinnedJourney == nil ? .secondary : .green
                )

                OnboardingCardListScroll(height: 270, showsIndicators: true) {
                    VStack(spacing: 10) {
                        if let selectedJourney = pinnedJourney {
                            MyJourneyCard(journey: PinnedJourney(from: selectedJourney)) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    pinnedJourney = nil
                                }
                                Haptics.impact(.light)
                            }
                        }

                        ForEach(connections.prefix(4).filter { $0.id != pinnedJourney?.id }) { connection in
                            let leaveTime = settingsManager.trainCommuteConfig.leaveTime(
                                for: connection,
                                fromStationId: originStation?.id
                            )
                            let displayConnection = DisplayConnection(
                                connection: connection,
                                leaveTime: leaveTime,
                                isSelected: false,
                                isPinned: pinnedJourney?.id == connection.id
                            )

                            ConnectionCard(
                                displayConnection: displayConnection,
                                onSchedule: {},
                                onCancel: {},
                                onPin: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        pinnedJourney = connection
                                    }
                                    Haptics.impact(.light)
                                },
                                onUnpin: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        pinnedJourney = nil
                                    }
                                    Haptics.impact(.light)
                                },
                                onTap: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        pinnedJourney = connection
                                    }
                                    Haptics.impact(.light)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private func stationPickerSheet(title: String, selection: Binding<Station?>) -> some View {
        StationPickerSheet(
            title: title,
            stations: popularStations,
            recentStations: recent,
            favoriteStations: favorites,
            searchHandler: { query in await searchStations(query: query) },
            onToggleFavorite: { station in settingsManager.toggleFavoriteStation(station) },
            selection: selection
        )
    }

    private func statusRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func emptyStateCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func loadPopularStationsIfNeeded() async {
        guard popularStations.isEmpty else { return }
        do {
            let stations = try await TransportService.shared.fetchStations()
            await MainActor.run { popularStations = Array(stations.prefix(40)) }
        } catch {
            await MainActor.run { popularStations = [] }
        }
    }

    private func refreshConnections() {
        fetchTask?.cancel()

        guard let originStation, let destinationStation, originStation.id != destinationStation.id else {
            isLoadingConnections = false
            usingSampleData = false
            connections = []
            pinnedJourney = nil
            return
        }

        pinnedJourney = nil
        isLoadingConnections = true
        usingSampleData = false

        fetchTask = Task {
            do {
                let fetched = try await withTimeout(seconds: 7) {
                    try await TransportService.shared.fetchConnections(
                        from: originStation,
                        to: destinationStation
                    )
                }

                await MainActor.run {
                    connections = fetched
                    isLoadingConnections = false
                }
            } catch {
                await MainActor.run {
                    connections = sampleConnections(from: originStation, to: destinationStation)
                    usingSampleData = true
                    isLoadingConnections = false
                }
            }
        }
    }

    private func searchStations(query: String) async -> [Station] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return popularStations }

        do {
            let remote = try await TransportService.shared.searchStations(matching: trimmed)
            return StationSearchService.rankStations(
                StationSearchService.mergeStations(primary: remote, secondary: popularStations), query: trimmed
            )
        } catch {
            return []
        }
    }

    private func sampleConnections(from origin: Station, to destination: Station) -> [TrainConnection] {
        let now = Date()
        let first = now.addingTimeInterval(9 * 60)
        let second = now.addingTimeInterval(18 * 60)
        let third = now.addingTimeInterval(27 * 60)

        return [
            TrainConnection(
                id: UUID().uuidString,
                lineNumber: "S1",
                trainType: .s,
                lineColors: nil,
                departureTime: first,
                arrivalTime: first.addingTimeInterval(18 * 60),
                departureStation: origin,
                arrivalStation: destination,
                platform: "3",
                delay: 0,
                status: .onTime,
                transfers: 0,
                legs: []
            ),
            TrainConnection(
                id: UUID().uuidString,
                lineNumber: "REX",
                trainType: TrainType(id: "REX", shortName: "REX", displayName: "REX"),
                lineColors: nil,
                departureTime: second,
                arrivalTime: second.addingTimeInterval(21 * 60),
                departureStation: origin,
                arrivalStation: destination,
                platform: "5",
                delay: 2,
                status: .delayed,
                transfers: 0,
                legs: []
            ),
            TrainConnection(
                id: UUID().uuidString,
                lineNumber: "S7",
                trainType: .s,
                lineColors: nil,
                departureTime: third,
                arrivalTime: third.addingTimeInterval(20 * 60),
                departureStation: origin,
                arrivalStation: destination,
                platform: "2",
                delay: 0,
                status: .onTime,
                transfers: 0,
                legs: []
            ),
        ]
    }
}

// MARK: - WidgetStepView

struct WidgetStepView: View {
    let step: OnboardingStep
    let pinnedJourney: TrainConnection?

    private let widgetPreviewSide: CGFloat = 164
    @ScaledMetric(relativeTo: .caption) private var stepNumberDiameter: CGFloat = 20

    private let instructionRows: [(String, String)] = [
        ("1", "Long press your Home Screen"),
        ("2", "Tap the + button in the top corner"),
        ("3", "Search for Gleis and add the widget"),
    ]

    var body: some View {
        OnboardingPanel(step: step) {
            VStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let entry = OnboardingWidgetPreviewEntry(
                        date: context.date,
                        data: widgetPreviewData(referenceDate: context.date)
                    )
                    VStack(spacing: 10) {
                        OnboardingWidgetPreviewSurface(title: "Small widget") {
                            OnboardingSmallWidgetView(entry: entry)
                                .frame(width: widgetPreviewSide)
                                .frame(minHeight: widgetPreviewSide, idealHeight: widgetPreviewSide)
                        }

                        OnboardingWidgetPreviewSurface(title: "Medium widget") {
                            // The ideal height fills the box; wrapped text that needs more makes it taller instead of cut.
                            OnboardingMediumWidgetView(entry: entry)
                                .frame(minHeight: widgetPreviewSide, idealHeight: widgetPreviewSide)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }

                VStack(spacing: 8) {
                    ForEach(instructionRows, id: \.0) { item in
                        HStack(spacing: 10) {
                            Text(item.0)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: stepNumberDiameter, height: stepNumberDiameter)
                                .background(Color(red: 0.11, green: 0.29, blue: 0.53), in: Circle())

                            Text(item.1)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private func widgetPreviewData(referenceDate: Date) -> WidgetData {
        if let pinnedJourney {
            let connection = WidgetConnection(
                id: pinnedJourney.id,
                lineNumber: pinnedJourney.lineNumber,
                lineColors: pinnedJourney.lineColors,
                departureTime: pinnedJourney.departureTime,
                arrivalTime: pinnedJourney.arrivalTime,
                destination: pinnedJourney.arrivalStation.name,
                platform: pinnedJourney.platform,
                transfers: pinnedJourney.transfers,
                delay: pinnedJourney.delay,
                stopCount: nil,
                hasReminder: false,
                isPinned: true
            )
            let leaveTime = max(referenceDate.addingTimeInterval(20), pinnedJourney.departureTime.addingTimeInterval(-5 * 60))
            return WidgetData(
                connections: [connection],
                leaveTimes: [leaveTime],
                fromStationName: pinnedJourney.departureStation.name,
                toStationName: pinnedJourney.arrivalStation.name,
                updatedAt: referenceDate
            )
        }

        let departure = referenceDate.addingTimeInterval(12 * 60)
        let arrival = departure.addingTimeInterval(18 * 60)
        let fallback = WidgetConnection(
            id: "onboarding-preview",
            lineNumber: "S1",
            departureTime: departure,
            arrivalTime: arrival,
            destination: "Flughafen",
            platform: "3",
            transfers: 0,
            delay: 0,
            stopCount: 5,
            hasReminder: false,
            isPinned: false
        )
        return WidgetData(
            connections: [fallback],
            leaveTimes: [referenceDate.addingTimeInterval(7 * 60)],
            fromStationName: "Wien Mitte",
            toStationName: "Flughafen",
            updatedAt: referenceDate
        )
    }
}

// MARK: - NotificationStepView

struct NotificationStepView: View {
    let step: OnboardingStep
    let pinnedJourney: TrainConnection?
    let notificationStatus: UNAuthorizationStatus
    let isRequestingPermission: Bool
    let onRequestPermission: () -> Void

    @StateObject private var settingsManager = SettingsManager.shared
    @ScaledMetric(relativeTo: .subheadline) private var appIconSize: CGFloat = 28

    private struct PreviewNotification: Identifiable {
        let type: NotificationType
        let title: String
        let body: String
        let fireDate: Date
        let interruptionLevel: UNNotificationInterruptionLevel

        var id: String { type == .fiveMinuteWarning ? "fiveMinuteWarning" : "exactTime" }
    }

    private var previewOrigin: Station {
        settingsManager.trainCommuteConfig.startStation
            ?? Station(id: "onboarding-notification-origin", name: "Wien Mitte", coordinate: nil)
    }

    private var previewDestination: Station {
        settingsManager.trainCommuteConfig.endStation
            ?? Station(id: "onboarding-notification-destination", name: "Flughafen Wien", coordinate: nil)
    }

    private var previewConnection: TrainConnection {
        if let pinnedJourney {
            return pinnedJourney
        }

        let config = settingsManager.trainCommuteConfig
        let travel = config.travelTime(for: previewOrigin.id) ?? config.walkingTimeMinutes
        let buffer = config.bufferTime(for: previewOrigin.id) ?? config.bufferTimeMinutes
        let departureTime = Date().addingTimeInterval(TimeInterval((travel + buffer + 20) * 60))

        return TrainConnection(
            id: "onboarding-notification-preview",
            lineNumber: "S1",
            trainType: .s,
            lineColors: nil,
            departureTime: departureTime,
            arrivalTime: departureTime.addingTimeInterval(18 * 60),
            departureStation: previewOrigin,
            arrivalStation: previewDestination,
            platform: "3",
            delay: 0,
            status: .onTime,
            transfers: 0,
            legs: []
        )
    }

    private var previewNotifications: [PreviewNotification] {
        let config = settingsManager.trainCommuteConfig
        let connection = previewConnection
        let leaveTime = config.leaveTime(for: connection, fromStationId: connection.departureStation.id)
        let types: [NotificationType] = [.fiveMinuteWarning, .exactTime]

        return types.map { type in
            let preview = NotificationService.shared.notificationPreview(
                for: connection,
                config: config,
                type: type
            )
            let rawDate = type == .fiveMinuteWarning ? leaveTime.addingTimeInterval(-5 * 60) : leaveTime
            let fireDate = max(rawDate, Date().addingTimeInterval(60))

            return PreviewNotification(
                type: type,
                title: preview.title,
                body: preview.body,
                fireDate: fireDate,
                interruptionLevel: preview.interruptionLevel
            )
        }
    }

    var body: some View {
        OnboardingPanel(step: step) {
            VStack(spacing: 14) {
                notificationPreview

                VStack(spacing: 10) {
                    Text("These are the reminders Gleis will send you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if notificationStatus == .authorized || notificationStatus == .provisional || notificationStatus == .ephemeral {
                        Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    } else {
                        Button {
                            onRequestPermission()
                        } label: {
                            HStack(spacing: 8) {
                                if isRequestingPermission {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "bell.badge.fill")
                                }

                                Text(isRequestingPermission ? "Requesting..." : "Enable Notifications")
                                    .font(.headline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.trainBlue)
                        )
                        .disabled(isRequestingPermission)
                    }
                }
                .padding(14)
                .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var notificationPreview: some View {
        VStack(spacing: 8) {
            ForEach(previewNotifications) { preview in
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            notificationAppHeader(fireDate: preview.fireDate)
                            Spacer()
                            interruptionTag(for: preview.interruptionLevel)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            notificationAppHeader(fireDate: preview.fireDate)
                            interruptionTag(for: preview.interruptionLevel)
                        }
                    }

                    Text(preview.title)
                        .font(.headline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(preview.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func notificationAppHeader(fireDate: Date) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.11, green: 0.29, blue: 0.53), Color(red: 0.18, green: 0.43, blue: 0.63)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "tram.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: appIconSize, height: appIconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text("Gleis")
                    .font(.subheadline.weight(.semibold))
                Text(fireDate, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func interruptionTag(for level: UNNotificationInterruptionLevel) -> some View {
        Text(level == .timeSensitive ? "Time sensitive" : "Active")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.12), in: Capsule())
    }
}

// MARK: - Shared Onboarding UI

struct OnboardingPanel<Content: View>: View {
    let step: OnboardingStep
    @ViewBuilder var content: Content

    @Environment(\.onboardingPanelMinHeight) private var minimumHeight
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(step.eyebrow)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(Color.trainBlue)
                    .tracking(1.2)

                Text(step.title)
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(step.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 12, y: 6)
    }
}

/// The page height a step's panel fills when its content is shorter, so the card still reaches the footer.
private struct OnboardingPanelMinHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var onboardingPanelMinHeight: CGFloat {
        get { self[OnboardingPanelMinHeightKey.self] }
        set { self[OnboardingPanelMinHeightKey.self] = newValue }
    }
}

/// A fixed-height card list with its own scroll; at accessibility sizes the cards grow into the page scroll instead.
private struct OnboardingCardListScroll<Content: View>: View {
    let height: CGFloat
    let showsIndicators: Bool
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            content
        } else {
            ScrollView(.vertical, showsIndicators: showsIndicators) { content }
                .frame(height: height)
        }
    }
}

struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGroupedBackground), Color(.secondarySystemGroupedBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color.white.opacity(0.55))
                .frame(width: 420, height: 320)
                .offset(x: 0, y: -280)
                .blur(radius: 20)

            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color.trainBlue.opacity(0.08))
                .frame(width: 360, height: 260)
                .offset(x: 120, y: 320)
                .blur(radius: 24)
        }
    }
}

struct OnboardingWidgetPreviewEntry {
    let date: Date
    let data: WidgetData?
}

struct OnboardingWidgetPreviewSurface<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            content
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                )
                .clipped()
        }
    }
}

struct OnboardingSmallWidgetView: View {
    let entry: OnboardingWidgetPreviewEntry

    var body: some View {
        if let data = entry.data, let current = onboardingCurrentWidgetConnection(for: data, at: entry.date) {
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            let conn = current.connection

            VStack(spacing: 0) {
                Text(data.routeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                OnboardingWidgetLineBadge(line: conn.lineNumber, lineColors: conn.lineColors, size: .small)
                    .padding(.top, 6)

                Spacer(minLength: 0)

                OnboardingWidgetCountdownDisplay(remaining: remaining, leaveTime: current.leaveTime)

                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    OnboardingWidgetDepartureInfo(connection: conn)
                    if conn.hasServiceAlert {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Service alert")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .background(onboardingWidgetGradient(remaining: remaining))
        } else {
            OnboardingWidgetEmptyState(size: .small, data: entry.data)
        }
    }
}

struct OnboardingMediumWidgetView: View {
    let entry: OnboardingWidgetPreviewEntry

    var body: some View {
        if let data = entry.data, let current = onboardingCurrentWidgetConnection(for: data, at: entry.date) {
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            let conn = current.connection

            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    OnboardingWidgetCountdownDisplay(remaining: remaining, leaveTime: current.leaveTime)

                    if remaining > 0 {
                        Text("Leave at \(current.leaveTime, style: .time)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minWidth: 95)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: 8) {
                    Text(data.routeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            OnboardingWidgetLineBadge(line: conn.lineNumber, lineColors: conn.lineColors, size: .medium)
                            destinationLabel(for: conn)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            OnboardingWidgetLineBadge(line: conn.lineNumber, lineColors: conn.lineColors, size: .medium)
                            destinationLabel(for: conn)
                        }
                    }

                    Spacer(minLength: 0)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) {
                            departureColumn(for: conn)
                            Spacer(minLength: 8)
                            platformColumn(for: conn, alignment: .trailing)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            departureColumn(for: conn)
                            platformColumn(for: conn, alignment: .leading)
                        }
                    }

                    if conn.isDelayed {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                            Text("+\(conn.delay) min").font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.orange)
                    }

                    if conn.hasServiceAlert {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                            Text("Service alert").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.red)
                    }
                }
                .padding(14)
            }
            .background(onboardingWidgetGradient(remaining: remaining))
        } else {
            OnboardingWidgetEmptyState(size: .medium, data: entry.data)
        }
    }

    private func destinationLabel(for conn: WidgetConnection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conn.destination)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if conn.isPinned {
                HStack(spacing: 2) {
                    Image(systemName: "pin.fill").font(.system(size: 7))
                    Text("My Journey").textCase(.uppercase).font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func departureColumn(for conn: WidgetConnection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Departs").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            if conn.isDelayed {
                // The struck timetable time moves above the live one when both do not fit on a line.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { delayedTimes(for: conn) }
                    VStack(alignment: .leading, spacing: 0) { delayedTimes(for: conn) }
                }
            } else {
                Text(onboardingWidgetTimeFormatter.string(from: conn.departureTime))
                    .font(.title2.weight(.bold).monospacedDigit())
                    .scalableText(minimumScale: 0.8)
            }
        }
    }

    @ViewBuilder private func delayedTimes(for conn: WidgetConnection) -> some View {
        Text(onboardingScheduledTime(conn.departureTime, delay: conn.delay))
            .font(.title3.weight(.medium).monospacedDigit())
            .strikethrough()
            .foregroundStyle(.secondary)
            .scalableText(minimumScale: 0.8)
        Text(onboardingWidgetTimeFormatter.string(from: conn.departureTime))
            .font(.title2.weight(.bold).monospacedDigit())
            .foregroundStyle(.orange)
            .scalableText(minimumScale: 0.8)
    }

    private func platformColumn(for conn: WidgetConnection, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("Platform").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(conn.platform ?? "–")
                .font(.title2.weight(.bold).monospacedDigit())
                .scalableText(minimumScale: 0.8)
        }
    }
}

struct OnboardingWidgetLineBadge: View {
    let line: String
    let lineColors: TrainLineColors?
    let size: BadgeSize

    enum BadgeSize {
        case small
        case medium

        var font: Font {
            switch self {
            case .small:
                .system(size: 12, weight: .bold)
            case .medium:
                .system(size: 14, weight: .bold)
            }
        }

        var verticalPadding: CGFloat { self == .small ? 4 : 5 }
        var horizontalPadding: CGFloat { self == .small ? 8 : 10 }
    }

    var body: some View {
        let style = Color.lineBadgeStyle(for: line, apiColors: lineColors)
        return Text(line)
            .font(size.font)
            .foregroundStyle(style.foreground)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, size.verticalPadding)
            .padding(.horizontal, size.horizontalPadding)
            .background(style.background, in: Capsule())
    }
}

struct OnboardingWidgetCountdownDisplay: View {
    let remaining: TimeInterval
    let leaveTime: Date

    private let mainFont: Font = .system(size: 28, weight: .bold, design: .rounded)
    private let labelFont: Font = .system(size: 10)

    var body: some View {
        VStack(spacing: 2) {
            if remaining <= 0 {
                Text("GO!")
                    .font(mainFont)
                    .foregroundStyle(.secondary)
                    .scalableText(minimumScale: 0.8)
            } else if remaining <= 60 {
                Text(leaveTime, style: .timer)
                    .font(mainFont.monospacedDigit())
                    .foregroundStyle(Color.urgency(for: remaining))
                    .multilineTextAlignment(.center)
                    .scalableText(minimumScale: 0.8)
                Text("to leave")
                    .font(labelFont.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(onboardingFormatCountdown(remaining))
                    .font(mainFont.monospacedDigit())
                    .foregroundStyle(Color.urgency(for: remaining))
                    .scalableText(minimumScale: 0.8)
                Text("to leave")
                    .font(labelFont.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct OnboardingWidgetDepartureInfo: View {
    let connection: WidgetConnection

    private let labelFont: Font = .system(size: 9, weight: .semibold)
    private let valueFont: Font = .subheadline.weight(.bold).monospacedDigit()
    private let delayFont: Font = .system(size: 10, weight: .bold)

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Departs").font(labelFont).foregroundStyle(.secondary)
                if connection.isDelayed {
                    HStack(spacing: 4) {
                        Text(onboardingWidgetTimeFormatter.string(from: connection.departureTime))
                            .font(valueFont)
                            .foregroundStyle(.orange)
                            .scalableText(minimumScale: 0.8)
                        Text("+\(connection.delay) min")
                            .font(delayFont)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(onboardingWidgetTimeFormatter.string(from: connection.departureTime))
                        .font(valueFont)
                        .scalableText(minimumScale: 0.8)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Platform").font(labelFont).foregroundStyle(.secondary)
                Text(connection.platform ?? "–").font(valueFont).scalableText(minimumScale: 0.8)
            }
        }
    }
}

struct OnboardingWidgetEmptyState: View {
    enum Size { case small, medium }

    let size: Size
    let data: WidgetData?

    var body: some View {
        let accentColor: Color = switch data?.state {
        case .fallback: .orange
        case .stale: .secondary
        default: .trainBlue
        }
        let title = switch data?.state {
        case .fallback: "Not up to date"
        case .stale: "No connections"
        default: "Set up route"
        }

        switch size {
        case .small:
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(accentColor.opacity(0.1)).frame(width: 48, height: 48)
                    Image(systemName: "tram.fill").font(.title3).foregroundStyle(accentColor)
                }
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .medium:
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(accentColor.opacity(0.1)).frame(width: 56, height: 56)
                    Image(systemName: "tram.fill").font(.title2).foregroundStyle(accentColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(WidgetData.emptyHintText(for: data)).font(.subheadline).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}

private let onboardingWidgetTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
}()

private func onboardingCurrentWidgetConnection(
    for data: WidgetData,
    at date: Date
) -> (connection: WidgetConnection, leaveTime: Date)? {
    let indexed = Array(zip(data.connections.indices, data.connections))
    for (index, connection) in indexed where index < data.leaveTimes.count {
        let leave = data.leaveTimes[index]
        if date < leave { return (connection, leave) }
    }
    if let lastIndex = data.connections.indices.last, lastIndex < data.leaveTimes.count {
        let connection = data.connections[lastIndex]
        if connection.departureTime > date {
            return (connection, data.leaveTimes[lastIndex])
        }
    }
    return nil
}

private func onboardingScheduledTime(_ actual: Date, delay: Int) -> String {
    let scheduled = actual.addingTimeInterval(TimeInterval(-delay * 60))
    return onboardingWidgetTimeFormatter.string(from: scheduled)
}

private func onboardingFormatCountdown(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int(ceil(max(0, seconds) / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 {
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

private func onboardingWidgetGradient(remaining: TimeInterval) -> some View {
    let color = Color.urgency(for: remaining)
    return LinearGradient(
        colors: [color.opacity(0.45), color.opacity(0.1), .clear],
        startPoint: .trailing,
        endPoint: .leading
    )
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.trainBlue)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground).opacity(configuration.isPressed ? 0.75 : 0.92), in: Capsule())
            .overlay(Capsule().stroke(Color.gray.opacity(0.2), lineWidth: 1))
            .foregroundStyle(.primary)
    }
}

// MARK: - Helpers

func withTimeout<R: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> R) async throws -> R {
    try await withThrowingTaskGroup(of: R.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
        .environmentObject(SettingsManager.shared)
}
