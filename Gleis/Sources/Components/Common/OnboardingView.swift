import SwiftUI
import UserNotifications
import UIKit

// MARK: - OnboardingView

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @StateObject private var settingsManager = SettingsManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var currentStepIndex = 0
    @State private var originStation: Station?
    @State private var destinationStation: Station?
    @State private var pinnedJourney: TrainConnection?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isRequestingNotificationPermission = false

    private let steps = OnboardingStep.allCases

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
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 20) {
                topBar

                TabView(selection: $currentStepIndex) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        stepView(step)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: currentStepIndex)

                footer
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .task { await refreshNotificationStatus() }
        .onChange(of: currentStepIndex) { _, _ in
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
        HStack {
            if currentStepIndex > 0 {
                Button {
                    withAnimation { currentStepIndex -= 1 }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
            } else {
                Color.clear.frame(width: 88, height: 36)
            }

            Spacer()

            Text("\(currentStepIndex + 1) / \(steps.count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemBackground), in: Capsule())

            Spacer()

            Button("Skip") { completeOnboarding() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(OnboardingSecondaryButtonStyle())
        }
        .padding(.horizontal, 20)
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
                HStack(spacing: 8) {
                    Text(isLastStep ? "Start Commuting" : "Continue")
                    Image(systemName: isLastStep ? "checkmark.circle.fill" : "arrow.right")
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
    case widget
    case notifications

    var eyebrow: String {
        switch self {
        case .welcome: "WELCOME"
        case .journey: "SETUP"
        case .widget: "WIDGET"
        case .notifications: "ALERTS"
        }
    }

    var title: String {
        switch self {
        case .welcome: "Your Real Train View"
        case .journey: "Pick Your Daily Route"
        case .widget: "See It On Your Home Screen"
        case .notifications: "Get The Right Nudge"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "This is the exact My Journey and connection card UI you get in the Train tab."
        case .journey: "Select origin and destination and preview the real connection cards from your route."
        case .widget: "Add the widget to your home screen for live departure, countdown, and platform info."
        case .notifications: "Allow alerts so Gleis can remind you when it is actually time to leave."
        }
    }

    var requiresPinnedJourney: Bool { false }
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
            ?? Station(id: "onboarding-origin", name: "Wien Mitte", coordinate: nil, transportTypes: [.trainCommute])
    }

    private var previewDestination: Station {
        settingsManager.trainCommuteConfig.endStation
            ?? Station(id: "onboarding-destination", name: "Flughafen Wien", coordinate: nil, transportTypes: [.trainCommute])
    }

    private var reusablePinnedJourney: PinnedJourney? {
        guard let journey = settingsManager.pinnedJourney, !journey.shouldAutoUnpin() else { return nil }
        return journey
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Exact Train Tab Cards", systemImage: "rectangle.stack.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(red: 0.11, green: 0.29, blue: 0.53))
                Spacer()
                Text("Live preview")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let referenceDate = context.date
                let samplePinnedJourney = makeSamplePinnedJourney(referenceDate: referenceDate)
                let previewPinnedJourney = reusablePinnedJourney ?? samplePinnedJourney
                let displayConnections = makeSampleDisplayConnections(referenceDate: referenceDate)

                ScrollView(.vertical, showsIndicators: false) {
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
                .frame(height: 360)
            }
        }
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        )
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
            Text("Setup checklist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            OnboardingCheckRow(
                title: "Choose your route",
                subtitle: "Set origin and destination in the Setup step.",
                isComplete: isJourneyConfigured,
                actionTitle: isJourneyConfigured ? nil : "Open Setup",
                action: isJourneyConfigured ? nil : onOpenSetup
            )
            OnboardingCheckRow(
                title: "Enable notifications",
                subtitle: "Receive leave-time reminders.",
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isComplete ? .green : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

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
        .padding(.vertical, 2)
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
                    statusRow(icon: "wifi.slash", text: "Offline preview shown. Pull to refresh after setup.", color: .orange)
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
            transportType: .trainCommute,
            startStation: originStation,
            endStation: destinationStation,
            travelTimeToStart: nil,
            travelTimeToEnd: nil,
            suggestedTravelTimeToStart: nil,
            suggestedTravelTimeToEnd: nil,
            bufferTimeToStart: nil,
            bufferTimeToEnd: nil,
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
                title: "Choose Two Stations",
                subtitle: "We will load the same connection cards you see in the Train tab."
            )
        } else if isLoadingConnections {
            VStack(spacing: 10) {
                ProgressView().tint(.trainBlue)
                Text("Finding departures...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if connections.isEmpty {
            emptyStateCard(
                icon: "exclamationmark.triangle",
                title: "No Connections Right Now",
                subtitle: "Try another station pair or continue and set it later in Train tab."
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    icon: pinnedJourney == nil ? "square.stack.3d.down.right" : "checkmark.circle.fill",
                    text: pinnedJourney == nil
                        ? "These are the real Train tab cards. Tap one to use it for onboarding previews."
                        : "Selected for onboarding previews. This does not pin it in the app.",
                    color: pinnedJourney == nil ? .secondary : .green
                )

                ScrollView {
                    VStack(spacing: 10) {
                        if let selectedJourney = pinnedJourney {
                            MyJourneyCard(journey: PinnedJourney(from: selectedJourney)) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    pinnedJourney = nil
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                },
                                onUnpin: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        pinnedJourney = nil
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                },
                                onTap: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        pinnedJourney = connection
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 270)
            }
        }
    }

    private func stationPickerSheet(title: String, selection: Binding<Station?>) -> some View {
        StationPickerSheet(
            title: title,
            stations: popularStations,
            recentStations: recent,
            favoriteStations: favorites,
            nearbyStations: [],
            stationDistances: [:],
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
            Spacer()
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
            let stations = try await TransportService.shared.fetchStations(for: .trainCommute)
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
                        to: destinationStation,
                        transportType: .trainCommute
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
            let remote = try await TransportService.shared.searchStations(
                matching: trimmed,
                transportType: .trainCommute
            )
            let merged = StationSearchRanker.mergeStations(primary: remote, secondary: popularStations)
            return StationSearchRanker.rank(merged, query: trimmed, preferShortNamesInTies: false)
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

    private let instructionRows: [(String, String)] = [
        ("1", "Long press your home screen"),
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
                        OnboardingWidgetPreviewSurface(title: "Small Widget") {
                            OnboardingSmallWidgetView(entry: entry)
                                .frame(width: 164, height: 164)
                        }

                        OnboardingWidgetPreviewSurface(title: "Medium Widget") {
                            OnboardingMediumWidgetView(entry: entry)
                                .frame(height: 164)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                VStack(spacing: 8) {
                    ForEach(instructionRows, id: \.0) { item in
                        HStack(spacing: 10) {
                            Text(item.0)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color(red: 0.11, green: 0.29, blue: 0.53), in: Circle())

                            Text(item.1)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)

                            Spacer()
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
                transportType: .trainCommute,
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
            transportType: .trainCommute,
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
            ?? Station(id: "onboarding-notification-origin", name: "Wien Mitte", coordinate: nil, transportTypes: [.trainCommute])
    }

    private var previewDestination: Station {
        settingsManager.trainCommuteConfig.endStation
            ?? Station(id: "onboarding-notification-destination", name: "Flughafen Wien", coordinate: nil, transportTypes: [.trainCommute])
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
                    Text("These are the exact notification texts scheduled by the app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if notificationStatus == .authorized || notificationStatus == .provisional || notificationStatus == .ephemeral {
                        Label("Notifications Enabled", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
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
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gleis")
                                .font(.subheadline.weight(.semibold))
                            Text(preview.fireDate, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(preview.interruptionLevel == .timeSensitive ? "Time Sensitive" : "Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.12), in: Capsule())
                    }

                    Text(preview.title)
                        .font(.headline.weight(.semibold))
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
}

// MARK: - Shared Onboarding UI

struct OnboardingPanel<Content: View>: View {
    let step: OnboardingStep
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(step.eyebrow)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(Color.trainBlue)
                    .tracking(1.2)

                Text(step.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(step.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(20)
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

struct HighlightTile: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color(red: 0.11, green: 0.29, blue: 0.53))
            Text(title)
                .font(.footnote.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StationSelectButton: View {
    let title: String
    let station: Station?
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(red: 0.11, green: 0.29, blue: 0.53))
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.11, green: 0.29, blue: 0.53).opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(station?.name ?? "Select Station")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(station == nil ? .secondary : .primary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
            WidgetJourneySmallCardContent(
                routeText: onboardingWidgetRouteText(for: data),
                connection: current.connection,
                leaveTime: current.leaveTime,
                referenceDate: entry.date
            )
            .background(onboardingWidgetGradient(remaining: remaining))
        } else {
            WidgetJourneyEmptyState(
                size: .small,
                data: entry.data,
                subtitle: onboardingEmptyHintText(for: entry.data)
            )
        }
    }
}

struct OnboardingMediumWidgetView: View {
    let entry: OnboardingWidgetPreviewEntry

    var body: some View {
        if let data = entry.data, let current = onboardingCurrentWidgetConnection(for: data, at: entry.date) {
            let remaining = current.leaveTime.timeIntervalSince(entry.date)
            WidgetJourneyMediumCardContent(
                routeText: onboardingWidgetRouteText(for: data),
                connection: current.connection,
                leaveTime: current.leaveTime,
                referenceDate: entry.date
            )
            .background(onboardingWidgetGradient(remaining: remaining))
        } else {
            WidgetJourneyEmptyState(
                size: .medium,
                data: entry.data,
                subtitle: onboardingEmptyHintText(for: entry.data)
            )
        }
    }
}

private func onboardingCurrentWidgetConnection(
    for data: WidgetData,
    at date: Date
) -> (connection: WidgetConnection, leaveTime: Date)? {
    data.connection(at: date)
}

private func onboardingWidgetRouteText(for data: WidgetData) -> String {
    let from = data.fromStationName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let to = data.toStationName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let from, !from.isEmpty, let to, !to.isEmpty { return "\(from) → \(to)" }
    return "From → To"
}

private func onboardingEmptyHintText(for data: WidgetData?) -> String {
    if let message = data?.stateMessage, !message.isEmpty { return message }
    switch data?.state {
    case .fallback:
        return "Open the app to refresh."
    case .stale:
        return "Check again soon or update route."
    default:
        return "Tap to set up your commute"
    }
}

private func onboardingWidgetGradient(remaining: TimeInterval) -> some View {
    let color = widgetJourneyUrgencyColor(remaining)
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
