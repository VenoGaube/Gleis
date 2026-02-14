import SwiftUI
import UIKit
import UserNotifications

// MARK: - OnboardingView

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0
    @Environment(\.colorScheme) var colorScheme

    // Onboarding journey data (passed between pages)
    @State private var originStation: Station?
    @State private var destinationStation: Station?
    @State private var pinnedJourney: TrainConnection?

    private let pages: [OnboardingPageType] = [.welcome, .interactiveSetup, .widgetShowcase, .notifications]

    var canContinue: Bool {
        switch pages[safe: currentPage] {
        case .interactiveSetup: pinnedJourney != nil
        default: true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Skip button
            HStack {
                Spacer()
                Button("Skip") { isPresented = false }.font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .padding()
            }

            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in pageView(for: page).tag(index) }
            }.tabViewStyle(.page(indexDisplayMode: .never)).onChange(of: currentPage) { _, _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            VStack(spacing: 24) {
                // Ellipse page indicator
                HStack(spacing: 6) {
                    ForEach(0 ..< pages.count, id: \.self) { index in
                        Capsule().fill(currentPage == index ? Color.accentColor : Color.gray.opacity(0.3)).frame(
                            width: currentPage == index ? 24 : 8, height: 8
                        ).animation(.spring(response: 0.3), value: currentPage).onTapGesture {
                            withAnimation { currentPage = index }
                        }
                    }
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if currentPage < pages.count - 1 {
                        withAnimation { currentPage += 1 }
                    } else {
                        completeOnboarding()
                    }
                } label: {
                    Text(currentPage < pages.count - 1 ? "Continue" : "Get Started").font(.headline).frame(
                        maxWidth: .infinity
                    ).padding(.vertical, 16)
                }.buttonStyle(.borderedProminent).disabled(!canContinue).opacity(canContinue ? 1.0 : 0.5).padding(
                    .horizontal, 32
                )
            }.padding(.bottom, 40)
        }.background {
            (colorScheme == .dark ? Color(UIColor.systemBackground) : Color(UIColor.systemGroupedBackground))
                .ignoresSafeArea(edges: .all)
        }.onDisappear {
            // Reset state when onboarding is dismissed
            currentPage = 0
            originStation = nil
            destinationStation = nil
            pinnedJourney = nil
        }
    }

    @ViewBuilder private func pageView(for page: OnboardingPageType) -> some View {
        switch page {
        case .welcome: PremiumWelcomeView()
        case .interactiveSetup:
            InteractiveJourneySetupView(
                originStation: $originStation, destinationStation: $destinationStation, pinnedJourney: $pinnedJourney
            )
        case .widgetShowcase: RealWidgetShowcaseView(pinnedJourney: pinnedJourney)
        case .notifications: SmartNotificationView(pinnedJourney: pinnedJourney)
        }
    }

    private func completeOnboarding() {
        // TODO: Transfer onboarding data to main app
        // If user set up a journey during onboarding, it should appear in the main app
        // This would require injecting TransportViewModel and setting the route

        isPresented = false
    }
}

// MARK: - OnboardingPageType

enum OnboardingPageType {
    case welcome
    case interactiveSetup
    case widgetShowcase
    case notifications
}

extension Collection { subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil } }

// MARK: - PremiumWelcomeView

// Page 1: Premium Welcome with Live App Preview
struct PremiumWelcomeView: View {
    @State private var countdownSeconds: TimeInterval = 180 // 3 minutes
    @State private var showPlatformUpdate = false
    @State private var urgencyState: UrgencyState = .calm
    @State private var timer: Timer?
    @Environment(\.colorScheme) var colorScheme

    enum UrgencyState {
        case calm // Green - >5min
        case warning // Orange - 1-5min
        case urgent // Red - <1min
    }

    var body: some View {
        ZStack {
            // Sophisticated gradient background
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.1, blue: 0.2), Color(red: 0.0, green: 0.48, blue: 0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // iPhone mockup with live app preview
                ZStack {
                    // iPhone bezel
                    RoundedRectangle(cornerRadius: 55).fill(colorScheme == .dark ? .black : Color(white: 0.15)).frame(
                        width: 300, height: 620
                    ).shadow(color: .black.opacity(0.4), radius: 40, y: 20)

                    // Dynamic Island (top cutout)
                    Capsule().fill(Color(red: 0.05, green: 0.1, blue: 0.2)).frame(width: 120, height: 35).offset(
                        y: -292)

                    // Screen content
                    RoundedRectangle(cornerRadius: 47).fill(
                        colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)
                    ).frame(width: 282, height: 600)

                    // Real ConnectionCard from production
                    VStack(spacing: 16) {
                        // Header
                        Text("My Journey").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).padding(
                            .horizontal, 12
                        ).padding(.vertical, 4).background(Color(red: 0.0, green: 0.48, blue: 0.85), in: Capsule())

                        // Actual ConnectionCard-style layout
                        VStack(spacing: 14) {
                            // Line badge + Destination
                            HStack(spacing: 12) {
                                Text("S1").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).padding(
                                    .horizontal, 12
                                ).padding(.vertical, 6).background(
                                    Color(red: 0.2, green: 0.6, blue: 0.3), in: RoundedRectangle(cornerRadius: 6)
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("to Flughafen").font(.system(size: 15, weight: .semibold))
                                    Text("Departing soon").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            // Live countdown - THE HERO ELEMENT
                            VStack(spacing: 8) {
                                // Circular progress ring
                                ZStack {
                                    Circle().stroke(Color.gray.opacity(0.2), lineWidth: 6).frame(
                                        width: 120, height: 120
                                    )

                                    Circle().trim(from: 0, to: countdownSeconds / 300.0).stroke(
                                        urgencyColor, style: StrokeStyle(lineWidth: 6, lineCap: .round)
                                    ).frame(width: 120, height: 120).rotationEffect(.degrees(-90)).animation(
                                        .linear(duration: 1), value: countdownSeconds
                                    )

                                    VStack(spacing: 4) {
                                        Text(formatTime(Int(countdownSeconds))).font(
                                            .system(size: 36, weight: .bold, design: .rounded)
                                        ).monospacedDigit().foregroundStyle(urgencyColor).contentTransition(
                                            .numericText())
                                        Text("to leave").font(.system(size: 11, weight: .medium)).foregroundStyle(
                                            .secondary)
                                    }
                                }
                            }

                            // Departure info with platform update animation
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("DEPARTURE").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                    Text("14:45").font(.system(size: 16, weight: .semibold)).monospacedDigit()
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("PLATFORM").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                    Text("3").font(.system(size: 16, weight: .semibold)).foregroundStyle(
                                        showPlatformUpdate ? .green : .primary)
                                }
                            }.padding(.horizontal, 4)

                            // Live indicator
                            HStack(spacing: 6) {
                                Circle().fill(urgencyColor).frame(width: 6, height: 6)
                                Text("Live tracking").font(.system(size: 10, weight: .medium)).foregroundStyle(
                                    .tertiary)
                                Spacer()
                            }
                        }.padding(18).background(
                            RoundedRectangle(cornerRadius: 20).fill(
                                colorScheme == .dark ? Color(.secondarySystemBackground) : .white
                            ).shadow(color: .black.opacity(0.1), radius: 12, y: 6)
                        ).padding(.horizontal, 20)
                    }.frame(width: 282, height: 600)
                }

                // Value proposition
                VStack(spacing: 12) {
                    Text("Never Miss Your Train").font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("Live countdowns, platform updates, and smart notifications").font(.body).foregroundStyle(
                        .white.opacity(0.9)
                    ).multilineTextAlignment(.center).padding(.horizontal, 40)
                }

                Spacer()
            }
        }.onAppear {
            startCountdownAnimation()
            startPlatformAnimation()
        }.onDisappear { timer?.invalidate() }
    }

    private var urgencyColor: Color {
        switch urgencyState {
        case .calm: .green
        case .warning: .orange
        case .urgent: .red
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        if seconds < 60 { "0:\(String(format: "%02d", seconds))" } else { "\(seconds / 60)m" }
    }

    private func startCountdownAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            withAnimation(.linear(duration: 1)) {
                if countdownSeconds > 0 {
                    countdownSeconds -= 1

                    // Update urgency state based on countdown
                    if countdownSeconds > 300 {
                        urgencyState = .calm
                    } else if countdownSeconds > 60 {
                        urgencyState = .warning
                    } else {
                        urgencyState = .urgent
                    }
                } else {
                    countdownSeconds = 180 // Reset to 3 minutes
                    urgencyState = .calm
                }
            }
        }
    }

    private func startPlatformAnimation() {
        Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showPlatformUpdate = true }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { showPlatformUpdate = false } }
        }
    }
}

// MARK: - InteractiveJourneySetupView

// Page 2: Interactive Journey Setup
struct InteractiveJourneySetupView: View {
    @Binding var originStation: Station?
    @Binding var destinationStation: Station?
    @Binding var pinnedJourney: TrainConnection?

    @State private var showOriginPicker = false
    @State private var showDestinationPicker = false
    @State private var connections: [TrainConnection] = []
    @State private var isLoading = false
    @State private var usingSampleData = false
    @State private var showSuccessAnimation = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            // Background
            (colorScheme == .dark ? Color(UIColor.systemBackground) : Color(UIColor.systemGroupedBackground))
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Title
                VStack(spacing: 12) {
                    Text("Let's Find Your First Train").font(.title.weight(.bold)).multilineTextAlignment(.center)

                    Text("Select where you're traveling from and to").font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }

                // Station selection buttons
                VStack(spacing: 12) {
                    StationSelectionButton(title: "From", station: originStation) { showOriginPicker = true }

                    StationSelectionButton(
                        title: "To", station: destinationStation
                    ) { showDestinationPicker = true }
                }.padding(.horizontal, 32)

                // Sample data notice
                if usingSampleData {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash").foregroundStyle(.orange)
                        Text("Using sample data - check your connection").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal)
                }

                // Connections list or loading
                if isLoading {
                    ProgressView().progressViewStyle(.circular).scaleEffect(1.2)
                } else if !connections.isEmpty {
                    VStack(spacing: 12) {
                        if pinnedJourney == nil {
                            Text("Tap the star to save your first journey").font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Journey saved!").font(.callout.weight(.semibold))
                            }.scaleEffect(showSuccessAnimation ? 1.1 : 1.0)
                        }

                        ScrollView {
                            VStack(spacing: 12) {
                                ForEach(connections.prefix(3)) { connection in
                                    OnboardingConnectionCard(
                                        connection: connection, isPinned: pinnedJourney?.id == connection.id
                                    ) {
                                        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                                            pinnedJourney = connection
                                            showSuccessAnimation = true
                                        }
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            withAnimation { showSuccessAnimation = false }
                                        }
                                    }
                                }
                            }.padding(.horizontal, 32)
                        }.frame(maxHeight: 300)
                    }
                }

                Spacer()
            }
        }.sheet(isPresented: $showOriginPicker) { StationPickerWrapper(selectedStation: $originStation) }.sheet(
            isPresented: $showDestinationPicker
        ) { StationPickerWrapper(selectedStation: $destinationStation) }.onChange(of: originStation) { _, _ in
            checkAndFetchConnections()
        }.onChange(of: destinationStation) { _, _ in checkAndFetchConnections() }
    }

    private func checkAndFetchConnections() {
        guard let origin = originStation, let destination = destinationStation, origin.id != destination.id else {
            connections = []
            return
        }

        Task { await fetchConnections(from: origin, to: destination) }
    }

    private func fetchConnections(from origin: Station, to destination: Station) async {
        isLoading = true
        usingSampleData = false

        do {
            try await withTimeout(seconds: 5) {
                let result = try await TransportService.shared.fetchConnections(
                    from: origin, to: destination, transportType: .trainCommute
                )

                await MainActor.run {
                    connections = result
                    isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                connections = createSampleConnections(from: origin, to: destination)
                usingSampleData = true
                isLoading = false
            }
        }
    }

    private func createSampleConnections(from origin: Station, to destination: Station) -> [TrainConnection] {
        let now = Date()
        let departure1 = now.addingTimeInterval(600) // 10 minutes from now
        let departure2 = now.addingTimeInterval(1200) // 20 minutes from now

        return [
            TrainConnection(
                id: UUID().uuidString, lineNumber: "S1", trainType: .s, departureTime: departure1,
                arrivalTime: departure1.addingTimeInterval(1200), departureStation: origin, arrivalStation: destination,
                platform: "3", delay: 0, status: .onTime, transfers: 0, legs: []
            ),
            TrainConnection(
                id: UUID().uuidString, lineNumber: "S2", trainType: .s, departureTime: departure2,
                arrivalTime: departure2.addingTimeInterval(1500), departureStation: origin, arrivalStation: destination,
                platform: "5", delay: 2, status: .delayed, transfers: 0, legs: []
            ),
        ]
    }
}

// Timeout helper function
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

// MARK: - TimeoutError

struct TimeoutError: Error {}

// MARK: - StationSelectionButton

// Station selection button
struct StationSelectionButton: View {
    let title: String
    let station: Station?
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(station?.name ?? "Select Station").font(.body.weight(.medium)).foregroundStyle(
                        station == nil ? .secondary : .primary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding().background(
                RoundedRectangle(cornerRadius: 12).fill(
                    colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color.white))
        }.buttonStyle(.plain)
    }
}

// MARK: - StationPickerWrapper

// Simplified wrapper for StationPicker (to avoid complex dependencies)
struct StationPickerWrapper: View {
    @Binding var selectedStation: Station?
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var stations: [Station] = []
    @State private var isSearching = false

    var body: some View {
        NavigationView {
            VStack {
                SearchField(text: $searchText).padding()

                if isSearching {
                    ProgressView()
                } else if stations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Search for a station").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(stations) { station in
                        Button {
                            selectedStation = station
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(station.name).font(.body)
                                    if !station.lines.isEmpty {
                                        Text(station.lines.prefix(3).joined(separator: ", ")).font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedStation?.id == station.id {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }
                    }.listStyle(.plain)
                }
            }.navigationTitle("Select Station").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }.onChange(of: searchText) { _, newValue in Task { await searchStations(query: newValue) } }.onAppear {
            Task { await loadPopularStations() }
        }
    }

    private func searchStations(query: String) async {
        guard !query.isEmpty else {
            await loadPopularStations()
            return
        }

        isSearching = true
        do {
            let results = try await TransportService.shared.searchStations(
                matching: query, transportType: .trainCommute
            )
            await MainActor.run {
                stations = results
                isSearching = false
            }
        } catch {
            await MainActor.run {
                stations = []
                isSearching = false
            }
        }
    }

    private func loadPopularStations() async {
        isSearching = true
        do {
            let allStations = try await TransportService.shared.fetchStations(for: .trainCommute)
            await MainActor.run {
                stations = Array(allStations.prefix(20))
                isSearching = false
            }
        } catch {
            await MainActor.run {
                stations = []
                isSearching = false
            }
        }
    }
}

// MARK: - SearchField

// Simple search field
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search stations", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }.padding(10).background(Color(.systemGray6)).cornerRadius(10)
    }
}

// MARK: - OnboardingConnectionCard

// Onboarding-specific connection card
struct OnboardingConnectionCard: View {
    let connection: TrainConnection
    let isPinned: Bool
    let onPin: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            // Line badge
            Text(connection.lineNumber).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).padding(
                .horizontal, 10
            ).padding(.vertical, 6).background(
                Color(red: 0.2, green: 0.6, blue: 0.3), in: RoundedRectangle(cornerRadius: 6)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.departureTime, style: .time).font(.body.weight(.semibold)).monospacedDigit()

                HStack(spacing: 4) {
                    if let platform = connection.platform {
                        Text("Pl. \(platform)").font(.caption).foregroundStyle(.secondary)
                    }
                    if connection.isDelayed { Text("+\(connection.delay) min").font(.caption).foregroundStyle(.orange) }
                }
            }

            Spacer()

            Button(action: onPin) {
                Image(systemName: isPinned ? "star.fill" : "star").font(.system(size: 20)).foregroundStyle(
                    isPinned ? .yellow : .secondary)
            }.buttonStyle(.plain)
        }.padding().background(
            RoundedRectangle(cornerRadius: 12).fill(
                colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color.white))
    }
}

// MARK: - SmartNotificationView

// Page 4: Smart Notifications (Updated to use dynamic journey data)
struct SmartNotificationView: View {
    let pinnedJourney: TrainConnection?
    @State private var animate = false
    @State private var showNotification = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isRequesting = false
    @Environment(\.colorScheme) var colorScheme

    var notificationText: String {
        if let journey = pinnedJourney {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            let time = timeFormatter.string(from: journey.departureTime)
            let platform = journey.platform ?? "TBD"
            return
                "\(journey.lineNumber) to \(journey.arrivalStation.name) departing at \(time) from Platform \(platform)"
        } else {
            return "S1 to Flughafen departing at 14:45 from Platform 3"
        }
    }

    var destinationName: String { pinnedJourney?.arrivalStation.name ?? "your destination" }

    var body: some View {
        ZStack {
            // Background extending to safe area
            (colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // Notification preview
                ZStack {
                    // Bell icon background
                    ZStack {
                        Circle().fill(.orange.opacity(0.15)).frame(width: 140, height: 140)

                        Circle().fill(.orange.opacity(0.1)).frame(width: 110, height: 110)

                        Image(systemName: "bell.badge.fill").font(.system(size: 60, weight: .medium)).foregroundStyle(
                            .orange
                        ).symbolEffect(.bounce, value: animate)
                    }.offset(y: 60).blur(radius: showNotification ? 8 : 0).opacity(showNotification ? 0.3 : 1)

                    // Notification card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            // App icon
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.0, green: 0.48, blue: 0.85),
                                            Color(red: 0.20, green: 0.50, blue: 0.65),
                                        ], startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                                Image(systemName: "tram.fill").font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }.frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gleis").font(.system(size: 14, weight: .semibold))
                                Text("now").font(.system(size: 12)).foregroundStyle(.secondary)
                            }

                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Time to Leave!").font(.system(size: 16, weight: .semibold))

                            Text(notificationText).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(
                                horizontal: false, vertical: true
                            )
                        }
                    }.padding(16).background(
                        RoundedRectangle(cornerRadius: 16).fill(
                            colorScheme == .dark ? Color(.secondarySystemBackground) : .white
                        ).shadow(color: .black.opacity(0.2), radius: 20, y: 10)
                    ).padding(.horizontal, 32).offset(y: showNotification ? 0 : -100).opacity(showNotification ? 1 : 0)
                }.frame(height: 250)

                // Enable notifications button
                if notificationStatus != .authorized, notificationStatus != .provisional {
                    Button {
                        Task { await requestNotificationPermission() }
                    } label: {
                        HStack(spacing: 10) {
                            if isRequesting {
                                ProgressView().progressViewStyle(.circular).tint(.white)
                            } else {
                                Image(systemName: "bell.badge.fill").font(.system(size: 16, weight: .semibold))
                            }
                            Text(isRequesting ? "Requesting..." : "Enable Notifications").font(
                                .system(size: 16, weight: .semibold))
                        }.foregroundStyle(.white).frame(maxWidth: 280).padding(.vertical, 16).background(
                            .orange, in: RoundedRectangle(cornerRadius: 14)
                        )
                    }.disabled(isRequesting).padding(.horizontal, 40)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Notifications Enabled").font(.system(size: 15, weight: .medium)).foregroundStyle(
                            .secondary)
                    }.padding(.vertical, 12)
                }

                // Content
                VStack(spacing: 12) {
                    Text("Never Miss Your Train").font(.title.weight(.bold)).multilineTextAlignment(.center)

                    Text("Get notified when it's time to leave for \(destinationName)").font(.body).foregroundStyle(
                        .secondary
                    ).multilineTextAlignment(.center).padding(.horizontal, 40)
                }

                Spacer()
            }
        }.onAppear {
            checkNotificationStatus()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    showNotification = true
                    animate.toggle()
                }
            }

            // Repeat animation
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { showNotification = false }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                        showNotification = true
                        animate.toggle()
                    }
                }
            }
        }
    }

    private func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { notificationStatus = settings.authorizationStatus }
        }
    }

    private func requestNotificationPermission() async {
        isRequesting = true
        defer { isRequesting = false }

        do {
            let granted = try await NotificationService.shared.requestAuthorization()
            await MainActor.run { notificationStatus = granted ? .authorized : .denied }
        } catch { await MainActor.run { notificationStatus = .denied } }
    }
}

// MARK: - RealWidgetShowcaseView

// Page 3: Real Widget Showcase
struct RealWidgetShowcaseView: View {
    let pinnedJourney: TrainConnection?
    @State private var animateWidget = false
    @State private var countdownSeconds: TimeInterval = 420 // 7 minutes
    @State private var timer: Timer?
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            // Background
            (colorScheme == .dark ? Color(UIColor.systemBackground) : Color(UIColor.systemGroupedBackground))
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Title
                VStack(spacing: 12) {
                    Text("Add to Your Home Screen").font(.title.weight(.bold)).multilineTextAlignment(.center)

                    Text("Stay updated with live countdown widgets").font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }

                // ACTUAL widget preview using shared components
                if let journey = pinnedJourney {
                    SmallWidgetUIView(
                        lineNumber: journey.lineNumber, destination: journey.arrivalStation.name,
                        countdown: formatWidgetCountdown(countdownSeconds),
                        urgencyColor: widgetUrgencyColor(countdownSeconds),
                        departureTime: formatTime(journey.departureTime), platform: journey.platform ?? "–",
                        isPinned: true
                    ).shadow(color: Color.black.opacity(0.2), radius: 20, y: 10).scaleEffect(animateWidget ? 1.02 : 1.0)
                } else {
                    // Fallback with sample data if no journey pinned
                    SmallWidgetUIView(
                        lineNumber: "S1", destination: "Flughafen", countdown: formatWidgetCountdown(countdownSeconds),
                        urgencyColor: widgetUrgencyColor(countdownSeconds), departureTime: "14:45", platform: "3",
                        isPinned: true
                    ).shadow(color: Color.black.opacity(0.2), radius: 20, y: 10).scaleEffect(animateWidget ? 1.02 : 1.0)
                }

                // How to add widget instructions
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.15)).frame(width: 32, height: 32)
                            Text("1").font(.system(size: 14, weight: .bold)).foregroundStyle(.blue)
                        }
                        Text("Long press on your home screen").font(.callout)
                    }

                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.15)).frame(width: 32, height: 32)
                            Text("2").font(.system(size: 14, weight: .bold)).foregroundStyle(.blue)
                        }
                        Text("Tap the + button").font(.callout)
                    }

                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.15)).frame(width: 32, height: 32)
                            Text("3").font(.system(size: 14, weight: .bold)).foregroundStyle(.blue)
                        }
                        Text("Search for Gleis and add your widget").font(.callout)
                    }
                }.padding(.horizontal, 40)

                // Feature highlights
                VStack(alignment: .leading, spacing: 10) {
                    FeatureRow(icon: "square.grid.2x2.fill", text: "Live countdown widgets", color: .purple)
                    FeatureRow(
                        icon: "star.fill", text: "Saved journeys", color: Color(red: 0.0, green: 0.48, blue: 0.85)
                    )
                    FeatureRow(icon: "checkmark.seal.fill", text: "Completely free, no ads", color: .green)
                }.padding(.horizontal, 40)

                Spacer()
            }
        }.onAppear { startAnimations() }.onDisappear { timer?.invalidate() }
    }

    private func startAnimations() {
        // Widget pulse animation
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { animateWidget = true }

        // Countdown animation
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            withAnimation(.linear(duration: 1)) {
                if countdownSeconds > 0 {
                    countdownSeconds -= 1
                } else {
                    countdownSeconds = 420 // Reset to 7 minutes
                }
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatWidgetCountdown(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "0:\(String(format: "%02d", Int(seconds)))"
        } else {
            let minutes = Int(seconds / 60)
            return "\(minutes)m"
        }
    }

    private func widgetUrgencyColor(_ seconds: TimeInterval) -> Color {
        if seconds <= 0 { .secondary } else if seconds < 120 { .red } else if seconds < 300 { .orange } else { .green }
    }
}

// MARK: - FeatureRow

struct FeatureRow: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(color).frame(width: 24)

            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)

            Spacer()
        }
    }
}

#Preview { OnboardingView(isPresented: .constant(true)) }

// MARK: - SmallWidgetUIView

struct SmallWidgetUIView: View {
    let lineNumber: String
    let destination: String
    let countdown: String
    let urgencyColor: Color
    let departureTime: String
    let platform: String
    let isPinned: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(lineNumber).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 10)
                    .padding(.vertical, 6).background(
                        Color(red: 0.2, green: 0.6, blue: 0.3), in: RoundedRectangle(cornerRadius: 6)
                    )

                Text(destination).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()

                if isPinned { Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small) }
            }

            HStack(alignment: .center) {
                // Countdown bubble
                ZStack {
                    Circle().fill(urgencyColor.opacity(0.15)).frame(width: 48, height: 48)
                    Text(countdown).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(
                        urgencyColor
                    ).monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock").foregroundStyle(.secondary).imageScale(.small)
                        Text(departureTime).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.grid.1x2").foregroundStyle(.secondary).imageScale(.small)
                        Text("Pl. \(platform)").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }.padding(14).frame(maxWidth: 320).background(
            RoundedRectangle(cornerRadius: 16).fill(
                colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : .white))
    }
}
