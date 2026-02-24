import SwiftUI

struct TransportView: View {
    @StateObject private var viewModel: TransportViewModel
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @EnvironmentObject private var settingsManager: SettingsManager
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
                    Text(viewModel.transportType.navigationTitle).font(.largeTitle.bold())
                    Spacer()
                    QuickTicketButton().font(.title2).padding(.trailing, 4)
                }

                if !networkMonitor.isConnected {
                    OfflineBanner()
                } else if viewModel.isServiceDegraded {
                    ServiceDegradedBanner(retryAt: viewModel.serviceRetryAt, lastUpdated: viewModel.lastUpdated)
                } else if viewModel.isShowingCachedData {
                    CachedDataBanner(lastUpdated: viewModel.lastUpdated)
                }

                if let recovery = viewModel.connectionRecovery {
                    ReminderRecoveryBanner(
                        recovery: recovery,
                        onApply: {
                            viewModel.acceptConnectionRecovery()
                        },
                        onDismiss: {
                            viewModel.dismissConnectionRecovery()
                        }
                    )
                }

                RouteHeader(
                    transportType: viewModel.transportType, startStation: startStation, endStation: endStation,
                    travelTimeToStart: viewModel.config.travelTime(for: startStation?.id),
                    travelTimeToEnd: viewModel.config.travelTime(for: endStation?.id),
                    suggestedTravelTimeToStart: nil,
                    suggestedTravelTimeToEnd: nil,
                    bufferTimeToStart: viewModel.config.bufferTime(for: startStation?.id),
                    bufferTimeToEnd: viewModel.config.bufferTime(for: endStation?.id), onSwap: swapStations,
                    onStartTap: { showStartPicker = true }, onEndTap: { showEndPicker = true },
                    onSetTravelTime: { showTravelTimeSheet = $0 }, onSetBufferTime: { showBufferTimeSheet = $0 }
                )

                // Train type filter chips
                if viewModel.connections.isLoaded, !viewModel.availableTrainTypes.isEmpty {
                    TrainTypeFilterBar(
                        availableTypes: viewModel.availableTrainTypes,
                        excludedTypes: Binding(
                            get: { viewModel.config.excludedTrainTypes },
                            set: { newValue in
                                var c = viewModel.config
                                c.excludedTrainTypes = newValue
                                settingsManager.updateConfig(c)
                            }
                        )
                    )
                }

                // My Journey section - shown separately when pinned
                if let pinnedJourney = settingsManager.pinnedJourney, !pinnedJourney.shouldAutoUnpin() {
                    let travel = viewModel.config.travelTime(for: pinnedJourney.departureStation.id)
                        ?? viewModel.config.walkingTimeMinutes
                    let buffer = viewModel.config.bufferTime(for: pinnedJourney.departureStation.id)
                        ?? viewModel.config.bufferTimeMinutes
                    let effectiveDeparture =
                        if viewModel.config.usesDelayInLeaveTime, pinnedJourney.delay > 0 {
                            pinnedJourney.departureTime.addingTimeInterval(TimeInterval(pinnedJourney.delay * 60))
                        } else {
                            pinnedJourney.departureTime
                        }
                    let pinnedLeaveTime = effectiveDeparture.addingTimeInterval(-TimeInterval((travel + buffer) * 60))
                    MyJourneyCard(
                        journey: pinnedJourney,
                        onUnpin: {
                            viewModel.unpinJourney()
                        },
                        leaveTime: pinnedLeaveTime
                    )
                }

                connectionsSection
            }.padding()
        }.background {
            (colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)).ignoresSafeArea(
                edges: .all)
        }.navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .navigationBar).refreshable {
            viewModel.cancelCurrentFetch()
            await viewModel.refreshConnections(showFeedback: true, isUserInitiated: true)
        }.onAppear {
            loadSavedStations()
            viewModel.startAutoRefresh()
            // Only fetch on first appearance; subsequent appears (tab switches) preserve state
            guard !hasAppearedOnce else { return }
            hasAppearedOnce = true
            viewModel.cancelCurrentFetch()
            Task { await viewModel.refreshConnections(isUserInitiated: true) }
        }
        .onDisappear { viewModel.stopAutoRefresh() }.onChange(of: scenePhase) { oldPhase, newPhase in
                // When app becomes active after being in background, refresh to filter out past connections
                if oldPhase != .active, newPhase == .active, hasAppearedOnce {
                    viewModel.cancelCurrentFetch()
                    Task { await viewModel.refreshConnections(isUserInitiated: false) }
                }
            }.onChange(of: startStation) { _, newValue in
                guard !isSwapping else { return }
                if let station = newValue { viewModel.addRecentStation(station) }
                updateConfig(start: newValue, end: endStation)
            }.onChange(of: endStation) { _, newValue in
                guard !isSwapping else { return }
                if let station = newValue { viewModel.addRecentStation(station) }
                updateConfig(start: startStation, end: newValue)
            }.sheet(isPresented: $showStartPicker) { stationPicker(title: "From", selection: $startStation) }.sheet(
                isPresented: $showEndPicker
            ) { stationPicker(title: "To", selection: $endStation) }.sheet(item: $detailConnection) {
                ConnectionDetailSheet(connection: $0)
            }.sheet(item: $showTravelTimeSheet) { station in
                TravelTimeSheet(station: station, currentValue: viewModel.config.travelTime(for: station.id)) { time in
                    settingsManager.saveTravelTime(time, for: station.id, transportType: viewModel.transportType)
                }
            }.sheet(item: $showBufferTimeSheet) { station in
                BufferTimeSheet(station: station, currentValue: viewModel.config.bufferTime(for: station.id)) { time in
                    settingsManager.saveBufferTime(time, for: station.id, transportType: viewModel.transportType)
                }
            }.toastOverlay(viewModel.toastManager).alert(
                viewModel.errorTitle ?? "Error", isPresented: $viewModel.showError
            ) {
                Button("OK") { viewModel.showError = false }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }.accentTheme(for: viewModel.transportType)
    }

    @ViewBuilder private var connectionsSection: some View {
        switch viewModel.connections {
        case .idle:
            if startStation == nil || endStation == nil {
                EmptyStateView(
                    icon: viewModel.transportType.icon, title: "Select Your Route",
                    message: "Tap the stations above to choose your start and destination"
                ).frame(maxWidth: .infinity).padding(.top, 40)
            }
        case .loading: SkeletonLoadingView(count: 3).padding(.top, 8)
        case .loaded:
            let displayConnections = Array(viewModel.displayConnections.prefix(viewModel.config.displayMaxConnections))
            if displayConnections.isEmpty {
                EmptyStateView(
                    icon: "tram.fill.tunnel", title: "No Connections",
                    message: "No upcoming connections found for this route",
                    action: { Task { await viewModel.refreshConnections() } }, actionTitle: "Refresh"
                ).frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                connectionsList(displayConnections)
            }
        case let .error(error):
            ErrorView(error: error) { Task { await viewModel.refreshConnections() } }.frame(maxWidth: .infinity)
                .padding(.top, 40)
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
                Text("Other connections").font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(
                    maxWidth: .infinity, alignment: .leading
                )
            }

            ForEach(sortedConnections) { displayConnection in
                ConnectionCard(
                    displayConnection: displayConnection,
                    onSchedule: { Task { await viewModel.scheduleNotification(for: displayConnection.connection) } },
                    onCancel: { viewModel.cancelNotification(for: displayConnection.connection) },
                    onPin: { viewModel.pinJourney(for: displayConnection.connection) },
                    onUnpin: { viewModel.unpinJourney() },
                    onTap: {
                        Haptics.selection()
                        detailConnection = displayConnection.connection
                    }
                ).id(displayConnection.id).overlay(
                    Group {
                        if highlightConnectionId == displayConnection.id {
                            RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: 3).animation(
                                .easeInOut(duration: 0.5).repeatCount(3), value: highlightConnectionId
                            )
                        }
                    })
            }
            if viewModel.isLoadingMore {
                SkeletonLoadingView(count: 1)
            } else if sortedConnections.count >= viewModel.config.displayMaxConnections {
                EndOfListFooter(count: sortedConnections.count)
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
            title: title, stations: viewModel.stations, recentStations: viewModel.config.recentStations,
            favoriteStations: viewModel.config.favoriteStations,
            nearbyStations: [],
            stationDistances: [:],
            searchHandler: { await viewModel.searchStations($0) },
            onToggleFavorite: { settingsManager.toggleFavoriteStation($0, for: viewModel.transportType) },
            selection: selection
        )
    }

    private func loadSavedStations() {
        startStation = viewModel.config.startStation
        endStation = viewModel.config.endStation
    }

    private func updateConfig(start: Station?, end: Station?) {
        var config = viewModel.config
        let oldStart = config.startStation
        let oldEnd = config.endStation
        let routeChanged = oldStart?.id != start?.id || oldEnd?.id != end?.id
        let changed = oldStart != start || oldEnd != end
        if changed { viewModel.selectedConnection = nil }
        config.startStation = start
        config.endStation = end
        settingsManager.updateConfig(config)
        if routeChanged { viewModel.cancelCurrentFetch() }
    }

    private func swapStations() {
        isSwapping = true
        withAnimation(.spring(response: 0.3)) {
            let tempStart = startStation
            startStation = endStation
            endStation = tempStart
        }
        Task { @MainActor in
            isSwapping = false
            updateConfig(start: startStation, end: endStation)
        }
    }

}

private struct ReminderRecoveryBanner: View {
    let recovery: ConnectionRecoveryState
    let onApply: () -> Void
    let onDismiss: () -> Void

    private var actionTitle: String {
        if let line = recovery.suggestedConnection?.lineNumber {
            return "Use \(line)"
        }
        return "Review"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: recovery.kind == .missingSelection ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.orange)
                Text(recovery.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            Text(recovery.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(actionTitle, action: onApply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }
}

#Preview {
    NavigationStack {
        TransportView(transportType: .trainCommute).environmentObject(SettingsManager.shared)
    }
}
