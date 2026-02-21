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
    @State private var isUserSelectingStart = false
    @State private var detailConnection: TrainConnection?
    @State private var isSwapping = false
    @State private var showTravelTimeSheet: Station?
    @State private var showBufferTimeSheet: Station?
    @State private var hasAppearedOnce = false

    let highlightConnectionId: String?
    private let commuteDirectionService = CommuteDirectionService.shared

    private var isLocationAuthorized: Bool {
        switch locationService.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            true
        default:
            false
        }
    }

    private var isAutoSelectionEnabled: Bool {
        settingsManager.appSettings.useLocationForStartStation
            && isLocationAuthorized
            && !viewModel.config.isStartStationManuallySelected
    }

    private var autoSelectionStatusMessage: String? {
        guard !isAutoSelectionEnabled else { return nil }

        if viewModel.config.isStartStationManuallySelected {
            return "Auto paused: station selected manually"
        }
        if !settingsManager.appSettings.useLocationForStartStation {
            return "Auto disabled in settings"
        }

        switch locationService.authorizationStatus {
        case .notDetermined:
            return "Allow location access to enable Auto"
        case .denied, .restricted:
            return "Location permission denied"
        default:
            return "Auto unavailable"
        }
    }

    private var autoPreferredStationIds: Set<String> {
        Set(settingsManager.appSettings.autoSelectionPreferences.areaPreferences.map(\.stationId))
    }

    private var autoExcludedStationIds: Set<String> {
        settingsManager.appSettings.autoSelectionPreferences.excludedStationIds
    }

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
                    suggestedTravelTimeToStart: startStation.flatMap {
                        viewModel.nearbyStationService.suggestedTravelTimeMinutes(for: $0.id)
                    },
                    suggestedTravelTimeToEnd: endStation.flatMap {
                        viewModel.nearbyStationService.suggestedTravelTimeMinutes(for: $0.id)
                    },
                    bufferTimeToStart: viewModel.config.bufferTime(for: startStation?.id),
                    bufferTimeToEnd: viewModel.config.bufferTime(for: endStation?.id), onSwap: swapStations,
                    isAutoSelectionEnabled: isAutoSelectionEnabled,
                    autoSelectionStatusMessage: autoSelectionStatusMessage,
                    onToggleAutoSelection: toggleAutoSelection,
                    onStartTap: { isUserSelectingStart = true; showStartPicker = true }, onEndTap: { showEndPicker = true },
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
                    MyJourneyCard(
                        journey: pinnedJourney
                    ) {
                        viewModel.unpinJourney()
                    }
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
        }.onReceive(locationService.$currentLocation) { _ in applyAutoStationSelectionIfNeeded() }
            .onDisappear { viewModel.stopAutoRefresh() }.onChange(of: scenePhase) { oldPhase, newPhase in
                // When app becomes active after being in background, refresh to filter out past connections
                if oldPhase != .active, newPhase == .active, hasAppearedOnce {
                    viewModel.cancelCurrentFetch()
                    Task { await viewModel.refreshConnections(isUserInitiated: false) }
                }
            }.onChange(of: startStation) { _, newValue in
                guard !isSwapping else { return }
                if let station = newValue { viewModel.addRecentStation(station) }
                let wasManuallySelected = viewModel.config.isStartStationManuallySelected
                updateConfig(start: newValue, end: endStation, manualStartSelection: isUserSelectingStart)
                // Show feedback when user first manually overrides auto-selection
                if isUserSelectingStart, !wasManuallySelected {
                    viewModel.toastManager.show("Auto-selection paused. Tap Auto Off to resume.", type: .info)
                }
                isUserSelectingStart = false
            }.onChange(of: endStation) { _, newValue in
                guard !isSwapping else { return }
                if let station = newValue { viewModel.addRecentStation(station) }
                updateConfig(start: startStation, end: newValue)
            }.sheet(isPresented: $showStartPicker) { stationPicker(title: "From", selection: $startStation) }.sheet(
                isPresented: $showEndPicker
            ) { stationPicker(title: "To", selection: $endStation) }.sheet(item: $detailConnection) {
                ConnectionDetailSheet(connection: $0)
            }.sheet(item: $showTravelTimeSheet) { station in
                TravelTimeSheet(
                    station: station, currentValue: viewModel.config.travelTime(for: station.id),
                    suggestedValue: viewModel.nearbyStationService.suggestedTravelTimeMinutes(for: station.id)
                ) { time in settingsManager.saveTravelTime(time, for: station.id, transportType: viewModel.transportType) }
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
            nearbyStations: viewModel.nearbyStationService.nearbyStations,
            stationDistances: viewModel.nearbyStationService.stationDistances,
            autoSelection: StationPickerAutoSelectionOptions(
                preferredStationIds: autoPreferredStationIds,
                excludedStationIds: autoExcludedStationIds,
                onSetPreferred: setPreferredAutoStation,
                onToggleExcluded: toggleAutoExcludedStation
            ),
            searchHandler: { await viewModel.searchStations($0) },
            onToggleFavorite: { settingsManager.toggleFavoriteStation($0, for: viewModel.transportType) },
            selection: selection
        )
    }

    private func loadSavedStations() {
        startStation = viewModel.config.startStation
        endStation = viewModel.config.endStation
        if settingsManager.appSettings.useLocationForStartStation { locationService.startUpdatingLocation() }
        applyAutoStationSelectionIfNeeded()
    }

    private func applyAutoStationSelectionIfNeeded(force: Bool = false) {
        guard settingsManager.appSettings.useLocationForStartStation else { return }
        guard force || !viewModel.config.isStartStationManuallySelected else { return }

        if applyCommuteDirectionIfNeeded() { return }
        autoSelectNearestStartStationIfNeeded()
    }

    private func applyCommuteDirectionIfNeeded() -> Bool {
        guard settingsManager.appSettings.useSmartStationSwap else {
            commuteDirectionService.reset()
            return false
        }

        let route = settingsManager.savedCommuteRoute
        guard let home = route.homeStation, let work = route.workStation, home.id != work.id else {
            commuteDirectionService.reset()
            return false
        }
        guard shouldUseSavedCommuteDirection(home: home, work: work) else {
            commuteDirectionService.reset()
            return false
        }
        guard let distanceToHome = locationService.distance(to: home),
              let distanceToWork = locationService.distance(to: work)
        else { return true }

        let direction = commuteDirectionService.resolveDirection(
            home: home,
            work: work,
            distanceToHome: distanceToHome,
            distanceToWork: distanceToWork,
            currentStart: startStation,
            currentEnd: endStation
        )

        guard let preferredStart = route.fromStation(for: direction),
              let preferredEnd = route.toStation(for: direction)
        else { return false }

        guard preferredStart.id != startStation?.id || preferredEnd.id != endStation?.id else { return true }
        withAnimation(.easeInOut(duration: 0.2)) {
            startStation = preferredStart
            endStation = preferredEnd
        }
        return true
    }

    private func shouldUseSavedCommuteDirection(home: Station, work: Station) -> Bool {
        let selectedIds = Set([startStation?.id, endStation?.id].compactMap { $0 })
        if selectedIds.isEmpty { return true }
        let commuteIds: Set<String> = [home.id, work.id]
        return selectedIds.isSubset(of: commuteIds)
    }

    private func autoSelectNearestStartStationIfNeeded() {
        if let preferred = preferredAutoStationCandidate() {
            guard preferred.id != startStation?.id else { return }
            startStation = preferred
            return
        }

        let destinationId = endStation?.id
        let excludedIds = autoExcludedStationIds
        let nearest =
            viewModel.nearbyStationService.nearbyStations.first {
                $0.id != destinationId && !excludedIds.contains($0.id)
            }
            ?? locationService.calculateDistances(to: viewModel.stations).first {
                $0.station.id != destinationId && !excludedIds.contains($0.station.id)
            }?.station
        guard let nearest, nearest.id != startStation?.id else { return }
        startStation = nearest
    }

    private func preferredAutoStationCandidate() -> Station? {
        guard let location = locationService.currentLocation else { return nil }
        guard let preferredId = settingsManager.appSettings.autoSelectionPreferences.preferredStationId(near: location),
              !autoExcludedStationIds.contains(preferredId),
              preferredId != endStation?.id
        else { return nil }

        if let station = viewModel.nearbyStationService.nearbyStations.first(where: { $0.id == preferredId }) {
            return station
        }
        if let station = viewModel.stations.first(where: { $0.id == preferredId }) { return station }
        if startStation?.id == preferredId { return startStation }
        if endStation?.id == preferredId { return endStation }
        return nil
    }

    private func setPreferredAutoStation(_ station: Station) {
        guard let location = locationService.currentLocation else {
            viewModel.toastManager.show("Location unavailable. Try again while location is active.", type: .info)
            return
        }

        settingsManager.setPreferredAutoSelectionStation(station, at: location)

        if isAutoSelectionEnabled {
            applyAutoStationSelectionIfNeeded(force: true)
        }

        viewModel.toastManager.show("Will prefer \(station.name) for auto-select near this area.", type: .success)
    }

    private func toggleAutoExcludedStation(_ station: Station) {
        let isNowExcluded = settingsManager.toggleAutoSelectionExclusion(for: station)

        if isAutoSelectionEnabled {
            applyAutoStationSelectionIfNeeded(force: true)
        }

        let message = isNowExcluded
            ? "\(station.name) will no longer be auto-selected."
            : "\(station.name) can now be auto-selected."
        viewModel.toastManager.show(message, type: .info)
    }

    private func toggleAutoSelection() {
        if isAutoSelectionEnabled {
            var config = viewModel.config
            config.isStartStationManuallySelected = true
            settingsManager.updateConfig(config)
            commuteDirectionService.reset()
            viewModel.toastManager.show("Auto-selection paused.", type: .info)
            return
        }

        var settings = settingsManager.appSettings
        if !settings.useLocationForStartStation {
            settings.useLocationForStartStation = true
            settingsManager.updateAppSettings(settings)
        }

        var config = viewModel.config
        config.isStartStationManuallySelected = false
        settingsManager.updateConfig(config)

        switch locationService.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationService.startUpdatingLocation()
            applyAutoStationSelectionIfNeeded(force: true)
            viewModel.toastManager.show("Auto-selection resumed.", type: .success)
        case .notDetermined:
            locationService.requestAuthorization()
            viewModel.toastManager.show("Allow location access to finish enabling Auto.", type: .info)
        default:
            viewModel.toastManager.show("Enable location permission in Settings to use Auto.", type: .info)
        }
    }

    private func updateConfig(start: Station?, end: Station?, manualStartSelection: Bool = false) {
        var config = viewModel.config
        let oldStart = config.startStation
        let oldEnd = config.endStation
        let routeChanged = oldStart?.id != start?.id || oldEnd?.id != end?.id
        let changed = oldStart != start || oldEnd != end
        if changed { viewModel.selectedConnection = nil }
        config.startStation = start
        config.endStation = end
        if manualStartSelection { config.isStartStationManuallySelected = true }
        settingsManager.updateConfig(config)
        if routeChanged {
            viewModel.cancelCurrentFetch()
            Task { await viewModel.refreshConnections(isUserInitiated: true) }
        }
    }

    private func swapStations() {
        isSwapping = true

        // First, perform the swap
        var tempStart = startStation
        var tempEnd = endStation
        swap(&tempStart, &tempEnd)

        // Smart swap only applies if NOT already manually overridden
        // Once user manually swaps, we respect their choice
        let wasManuallySelected = viewModel.config.isStartStationManuallySelected
        if !wasManuallySelected,
           settingsManager.appSettings.useSmartStationSwap,
           let unwrappedStart = tempStart, let unwrappedEnd = tempEnd,
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
            // Swap is a manual action, so set the override flag
            updateConfig(start: startStation, end: endStation, manualStartSelection: true)
            // Show feedback that auto-selection is now paused
            if !wasManuallySelected {
                viewModel.toastManager.show("Auto-selection paused. Tap Auto Off to resume.", type: .info)
            }
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
        TransportView(transportType: .trainCommute).environmentObject(SettingsManager.shared).environmentObject(
            LocationService.shared)
    }
}
