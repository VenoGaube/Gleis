import CoreLocation
import SwiftUI

struct TransportView: View {
    @StateObject private var viewModel: TransportViewModel
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var locationService: LocationService
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var startStation: Station?
    @State private var endStation: Station?
    @State private var showStartPicker = false
    @State private var showEndPicker = false
    @State private var detailConnection: TrainConnection?
    @State private var isSwapping = false
    @State private var showTravelTimeSheet: Station?
    @State private var showBufferTimeSheet: Station?
    @State private var hasAppearedOnce = false

    let highlightConnectionId: String?

    init(transportType: TransportType, highlightConnectionId: String? = nil) {
        _viewModel = StateObject(wrappedValue: TransportViewModel(transportType: transportType))
        self.highlightConnectionId = highlightConnectionId
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(alignment: .center) {
                    Text(viewModel.transportType.navigationTitle)
                        .font(.largeTitle.bold())
                    Spacer()
                    QuickTicketButton()
                        .font(.title2)
                        .padding(.trailing, 4)
                }

                if !networkMonitor.isConnected { OfflineBanner() }
                else if viewModel.isShowingCachedData { CachedDataBanner(lastUpdated: viewModel.lastUpdated) }

                RouteHeader(
                    transportType: viewModel.transportType,
                    startStation: startStation,
                    endStation: endStation,
                    travelTimeToStart: viewModel.config.travelTime(for: startStation?.id),
                    travelTimeToEnd: viewModel.config.travelTime(for: endStation?.id),
                    bufferTimeToStart: viewModel.config.bufferTime(for: startStation?.id),
                    bufferTimeToEnd: viewModel.config.bufferTime(for: endStation?.id),
                    onSwap: swapStations,
                    onStartTap: { showStartPicker = true },
                    onEndTap: { showEndPicker = true },
                    onSetTravelTime: { showTravelTimeSheet = $0 },
                    onSetBufferTime: { showBufferTimeSheet = $0 }
                )

                // My Journey section - shown separately when pinned
                if let pinnedJourney = settingsManager.pinnedJourney, !pinnedJourney.shouldAutoUnpin() {
                    MyJourneyCard(
                        journey: pinnedJourney,
                        onUnpin: { viewModel.unpinJourney(for: TrainConnection(
                            id: pinnedJourney.connectionId,
                            lineNumber: pinnedJourney.lineNumber,
                            departureTime: pinnedJourney.departureTime,
                            arrivalTime: pinnedJourney.arrivalTime,
                            departureStation: pinnedJourney.departureStation,
                            arrivalStation: pinnedJourney.arrivalStation,
                            platform: pinnedJourney.platform,
                            delay: pinnedJourney.delay,
                            status: .onTime,
                            transfers: pinnedJourney.transfers,
                            legs: pinnedJourney.legs
                        )) }
                    )
                }

                connectionsSection
            }
            .padding()
        }
        .background {
            (colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground))
                .ignoresSafeArea(edges: .all)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { viewModel.cancelCurrentFetch(); await viewModel.refreshConnections(
            showFeedback: true,
            isUserInitiated: true
        ) }
        .onAppear {
            loadSavedStations()
            viewModel.startAutoRefresh()
            // Only fetch on first appearance; subsequent appears (tab switches) preserve state
            guard !hasAppearedOnce else { return }
            hasAppearedOnce = true
            viewModel.cancelCurrentFetch()
            Task { await viewModel.refreshConnections(isUserInitiated: true) }
        }
        .onReceive(locationService.$currentLocation.first { $0 != nil }) { _ in autoSelectStartStationIfNeeded() }
        .onDisappear { viewModel.stopAutoRefresh() }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // When app becomes active after being in background, refresh to filter out past connections
            if oldPhase != .active, newPhase == .active, hasAppearedOnce {
                viewModel.cancelCurrentFetch()
                Task { await viewModel.refreshConnections(isUserInitiated: false) }
            }
        }
        .onChange(of: startStation) { _, newValue in
            guard !isSwapping else { return }; if let station = newValue { viewModel.addRecentStation(station) }; updateConfig(
                start: newValue,
                end: endStation
            )
        }
        .onChange(of: endStation) { _, newValue in
            guard !isSwapping else { return }; if let station = newValue { viewModel.addRecentStation(station) }; updateConfig(
                start: startStation,
                end: newValue
            )
        }
        .sheet(isPresented: $showStartPicker) { stationPicker(title: "From", selection: $startStation) }
        .sheet(isPresented: $showEndPicker) { stationPicker(title: "To", selection: $endStation) }
        .sheet(item: $detailConnection) { ConnectionDetailSheet(connection: $0) }
        .sheet(item: $showTravelTimeSheet) { station in TravelTimeSheet(
            station: station,
            currentValue: viewModel.config.travelTime(for: station.id)
        ) { time in updateTravelTime(time, for: station) } }
        .sheet(item: $showBufferTimeSheet) { station in BufferTimeSheet(
            station: station,
            currentValue: viewModel.config.bufferTime(for: station.id)
        ) { time in updateBufferTime(time, for: station) } }
        .overlay(alignment: .bottom) { if let toast = viewModel.toast { ToastView(
            message: toast.message,
            type: toast.type
        ).transition(.move(edge: .bottom).combined(with: .opacity)).padding(.bottom, 20) } }
        .animation(.spring(response: 0.3), value: viewModel.toast?.message)
        .alert("Error", isPresented: $viewModel.showError) { Button("OK") { viewModel.showError = false } } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .accentTheme(for: viewModel.transportType)
    }

    @ViewBuilder
    private var connectionsSection: some View {
        switch viewModel.connections {
        case .idle:
            if startStation == nil || endStation == nil {
                EmptyStateView(
                    icon: viewModel.transportType.icon,
                    title: "Select Your Route",
                    message: "Tap the stations above to choose your start and destination"
                ).frame(maxWidth: .infinity).padding(.top, 40)
            }
        case .loading:
            SkeletonLoadingView(count: 3).padding(.top, 8)
        case .loaded:
            let displayConnections = Array(viewModel.displayConnections.prefix(viewModel.config.displayMaxConnections))
            if displayConnections.isEmpty {
                EmptyStateView(
                    icon: "tram.fill.tunnel",
                    title: "No Connections",
                    message: "No upcoming connections found for this route",
                    action: { Task { await viewModel.refreshConnections() } },
                    actionTitle: "Refresh"
                ).frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                connectionsList(displayConnections)
            }
        case let .error(error):
            ErrorView(error: error) { Task { await viewModel.refreshConnections() } }.frame(maxWidth: .infinity)
                .padding(
                    .top,
                    40
                )
        }
    }

    private func connectionsList(_ displayConnections: [DisplayConnection]) -> some View {
        // Filter out pinned journey (it's shown in the separate MyJourneyCard)
        // Filter out past connections (already handled in ViewModel)
        let pinnedId = settingsManager.pinnedJourney?.connectionId
        let filteredConnections = displayConnections.filter { $0.connection.id != pinnedId && !$0.isMissed }
        let sortedConnections = filteredConnections.sorted { $0.connection.departureTime < $1.connection.departureTime }

        return VStack(spacing: 12) {
            if sortedConnections.isEmpty, pinnedId != nil {
                // All connections filtered out because one is pinned - show helpful message
                Text("Other connections")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(sortedConnections) { displayConnection in
                ConnectionCard(
                    displayConnection: displayConnection,
                    onSchedule: { Task { await viewModel.scheduleNotification(for: displayConnection.connection) } },
                    onCancel: { viewModel.cancelNotification(for: displayConnection.connection) },
                    onPin: { viewModel.pinJourney(for: displayConnection.connection) },
                    onUnpin: { viewModel.unpinJourney(for: displayConnection.connection) },
                    onTap: {
                        guard displayConnection.connection.transfers > 0 else { return }
                        Haptics.selection()
                        detailConnection = displayConnection.connection
                    }
                )
                .id(displayConnection.id)
                .overlay(
                    Group {
                        if highlightConnectionId == displayConnection.id {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.accentColor, lineWidth: 3)
                                .animation(.easeInOut(duration: 0.5).repeatCount(3), value: highlightConnectionId)
                        }
                    }
                )
            }
            if viewModel.isLoadingMore {
                SkeletonLoadingView(count: 1)
            } else {
                BottomScrollSentinel(
                    onScrollPastEnd: { Task { await viewModel.loadMoreConnections() } },
                    isLoading: viewModel.isLoadingMore
                )
            }
        }
    }

    private func stationPicker(title: String, selection: Binding<Station?>) -> some View {
        StationPickerSheet(
            title: title,
            stations: viewModel.stations,
            recentStations: viewModel.config.recentStations,
            favoriteStations: viewModel.config.favoriteStations,
            nearbyStations: viewModel.nearbyStations,
            stationDistances: viewModel.stationDistances,
            searchHandler: { await viewModel.searchStations($0) },
            onToggleFavorite: toggleFavorite,
            selection: selection
        )
    }

    private func loadSavedStations() {
        startStation = viewModel.config.startStation
        endStation = viewModel.config.endStation
        if settingsManager.appSettings.useLocationForStartStation { locationService.startUpdatingLocation() }
    }

    private func autoSelectStartStationIfNeeded() {
        guard startStation == nil, settingsManager.appSettings.useLocationForStartStation,
              let nearest = locationService.findNearestStation(from: viewModel.stations) else { return }
        startStation = nearest
    }

    private func updateConfig(start: Station?, end: Station?) {
        var config = viewModel.config
        let oldStart = config.startStation
        let oldEnd = config.endStation
        let changed = oldStart != start || oldEnd != end
        if changed {
            viewModel.selectedConnection = nil
        }
        config.startStation = start; config.endStation = end
        settingsManager.updateConfig(config)
    }

    private func toggleFavorite(_ station: Station) {
        var config = viewModel.config
        config.toggleFavoriteStation(station)
        settingsManager.updateConfig(config)
    }

    private func swapStations() {
        isSwapping = true

        // First, perform the swap
        var tempStart = startStation
        var tempEnd = endStation
        swap(&tempStart, &tempEnd)

        // Smart swap: Ensure closest station is the start if enabled
        if settingsManager.appSettings.useSmartStationSwap,
           let unwrappedStart = tempStart,
           let unwrappedEnd = tempEnd,
           let distanceToTempStart = locationService.distance(to: unwrappedStart),
           let distanceToTempEnd = locationService.distance(to: unwrappedEnd),
           distanceToTempEnd < distanceToTempStart
        {
            // End station is actually closer, swap them back to maintain proximity order
            swap(&tempStart, &tempEnd)
        }

        // Apply the changes with animation
        withAnimation(.spring(response: 0.3)) {
            startStation = tempStart
            endStation = tempEnd
        }

        Task { @MainActor in
            isSwapping = false
            updateConfig(start: startStation, end: endStation)
        }
    }

    private func updateTravelTime(_ minutes: Int?, for station: Station) {
        var config = viewModel.config
        config.setTravelTime(minutes, for: station.id)
        settingsManager.updateConfig(config)
    }

    private func updateBufferTime(_ minutes: Int?, for station: Station) {
        var config = viewModel.config
        config.setBufferTime(minutes, for: station.id)
        settingsManager.updateConfig(config)
    }
}

#Preview {
    NavigationStack {
        TransportView(transportType: .trainCommute)
            .environmentObject(SettingsManager.shared)
            .environmentObject(LocationService.shared)
    }
}
