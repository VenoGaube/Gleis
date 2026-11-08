import SwiftUI

struct TransportView: View {
    @StateObject private var viewModel: TransportViewModel
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @EnvironmentObject private var settingsManager: SettingsManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var startStation: Station?
    @State private var endStation: Station?
    @State private var showStartPicker = false
    @State private var showEndPicker = false
    @State private var showDepartureTimeSheet = false
    @State private var detailConnection: DisplayConnection?
    @State private var isSwapping = false
    @State private var activeTimingSheet: TimingSheet?
    @State private var hasAppearedOnce = false
    @State private var isPassedSectionExpanded = false
    @State private var expandedConnectionIds: Set<String> = []
    @State private var jumpsInFlight = 0
    @State private var didApplyDebugLaunchOptions = false

    let highlightConnectionId: String?
    let scrollToTopTrigger: Int

    init(highlightConnectionId: String? = nil, scrollToTopTrigger: Int = 0) {
        _viewModel = StateObject(wrappedValue: TransportViewModel())
        self.highlightConnectionId = highlightConnectionId
        self.scrollToTopTrigger = scrollToTopTrigger
    }

    private let topAnchorId = "transport-top-anchor"

    private var isRouteValid: Bool {
        guard let startStation, let endStation else { return false }
        return startStation.id != endStation.id
    }

    private var pinnedConnectionId: String? { settingsManager.pinnedJourney?.connectionId }

    private var savedRouteStationIds: [String?] {
        [settingsManager.trainCommuteConfig.startStation?.id, settingsManager.trainCommuteConfig.endStation?.id]
    }

    private var toggleAnimation: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .gleisToggle }
    private var pinAnimation: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .snappy }
    private var pinTransition: AnyTransition { reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity) }

    var body: some View {
        let liveRows = makeLiveConnectionRows()
        let anchoredRows = visibleAnchoredRows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    topSection.padding(.bottom, 8)
                    connectionsSection(liveRows: liveRows, anchoredRows: anchoredRows)
                }
                .padding()
                .animation(reduceMotion ? nil : .gleisList, value: rowIds(liveRows: liveRows, anchoredRows: anchoredRows))
                .animation(.easeInOut(duration: 0.25), value: sectionPhaseKey)
            }
            .onChange(of: scrollToTopTrigger) { _, _ in
                if viewModel.departureAnchor != nil { returnToNow() }
                withAnimation(reduceMotion ? nil : .easeInOut) { proxy.scrollTo(topAnchorId, anchor: .top) }
            }
            .onChange(of: deepLinkScrollTargetId) { _, targetId in
                if targetId != nil { scrollToHighlightedConnection(with: proxy) }
            }
            .onAppear { scrollToHighlightedConnection(with: proxy) }
        }.background {
            Color.screenBackground(colorScheme).ignoresSafeArea(
                edges: .all)
        }.navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .navigationBar).refreshable {
            if viewModel.departureAnchor != nil {
                await runTrackingJump { await viewModel.rerunJump() }
            } else {
                await viewModel.refreshConnections(isUserInitiated: true)
            }
        }.onAppear {
            loadSavedStations()
            viewModel.startAutoRefresh()
            applyDebugLaunchOptionsIfReady()
            // Only fetch on first appearance; subsequent appears (tab switches) preserve state
            guard !hasAppearedOnce else { return }
            hasAppearedOnce = true
            Task { await viewModel.refreshConnections(isUserInitiated: true) }
        }
        .onDisappear { viewModel.stopAutoRefresh() }.onChange(of: scenePhase) { oldPhase, newPhase in
                // When app becomes active after being in background, refresh to drop departed connections
                if oldPhase != .active, newPhase == .active, hasAppearedOnce {
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
            }.onChange(of: savedRouteStationIds) { _, _ in
                followSavedRoute()
            }.onChange(of: viewModel.displayConnections.isEmpty) { _, _ in
                applyDebugLaunchOptionsIfReady()
            }.sheet(isPresented: $showStartPicker) { stationPicker(title: "From", selection: $startStation) }.sheet(
                isPresented: $showEndPicker
            ) { stationPicker(title: "To", selection: $endStation) }.sheet(item: $detailConnection) {
                detailSheet(for: $0)
            }.sheet(isPresented: $showDepartureTimeSheet) {
                DepartureTimeSheet(
                    anchor: viewModel.departureAnchor,
                    onApply: { startJump(to: $0) },
                    onBackToNow: returnToNow
                )
                .presentationDetents([.medium, .large])
            }.sheet(item: $activeTimingSheet) { sheet in
                switch sheet {
                case let .travel(station):
                    TravelTimeSheet(station: station, currentValue: viewModel.config.travelTime(for: station.id)) { time in
                        settingsManager.saveTravelTime(time, for: station.id)
                    }
                case let .buffer(station):
                    BufferTimeSheet(station: station, currentValue: viewModel.config.bufferTime(for: station.id)) { time in
                        settingsManager.saveBufferTime(time, for: station.id)
                    }
                }
            }.toastOverlay(viewModel.toastManager).alert(
                viewModel.errorTitle ?? "Error", isPresented: $viewModel.showError
            ) {
                Button("OK") { viewModel.showError = false }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }.tint(.trainBlue)
    }

    // MARK: Top section

    private var topSection: some View {
        VStack(spacing: 20) {
            titleRow.id(topAnchorId)

            if !networkMonitor.isConnected {
                OfflineBanner()
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
                startStation: startStation, endStation: endStation,
                travelTimeToStart: viewModel.config.travelTime(for: startStation?.id),
                bufferTimeToStart: viewModel.config.bufferTime(for: startStation?.id), onSwap: swapStations,
                onStartTap: { showStartPicker = true }, onEndTap: { showEndPicker = true },
                onSetTravelTime: { activeTimingSheet = .travel($0) }, onSetBufferTime: { activeTimingSheet = .buffer($0) },
                departureAnchor: viewModel.departureAnchor,
                onDepartureChipTap: isRouteValid ? { showDepartureTimeSheet = true } : nil,
                onClearDepartureAnchor: returnToNow
            )

            if showsRefreshErrorBanner {
                RefreshErrorBanner(
                    title: viewModel.lastRefreshError?.userFacingTitle ?? "Live updates are delayed",
                    onRetry: { Task { await viewModel.refreshConnections(isUserInitiated: true) } }
                )
            }

            if viewModel.connections.isLoaded || viewModel.anchoredConnections.isLoaded,
               !viewModel.availableTrainTypes.isEmpty
            {
                TrainTypeFilterBar(
                    availableTypes: viewModel.availableTrainTypes,
                    excludedTypes: Binding(
                        get: { viewModel.config.excludedTrainTypes },
                        set: { setExcludedTrainTypes($0) }
                    )
                )
            }

            // The arrival check needs no per-second tick: MyJourneyCard draws its own countdown.
            if let pinnedJourney = settingsManager.pinnedJourney, !pinnedJourney.shouldAutoUnpin() {
                TimelineView(.everyMinute) { context in
                    if !pinnedJourney.shouldAutoUnpin(currentDate: context.date) {
                        myJourneyCard(for: pinnedJourney)
                    }
                }
                .transition(pinTransition)
            }
        }
    }

    /// Side by side normally; stacked at accessibility sizes so the "Updated" text keeps a full line.
    @ViewBuilder private var titleRow: some View {
        let title = Text("Train").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                title
                freshnessBadge
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 12) {
                title.layoutPriority(1)
                Spacer(minLength: 0)
                freshnessBadge
            }
        }
    }

    @ViewBuilder private var freshnessBadge: some View {
        if viewModel.departureAnchor == nil, viewModel.connections.isLoaded {
            DataFreshnessBadge(
                isStale: viewModel.isShowingCachedData || viewModel.isServiceDegraded || viewModel.lastRefreshError != nil,
                lastUpdated: viewModel.lastUpdated
            )
        }
    }

    /// An empty list shows its error inline instead, so each failure appears once.
    private var showsRefreshErrorBanner: Bool {
        guard viewModel.departureAnchor == nil, viewModel.connections.isLoaded,
              viewModel.lastRefreshError != nil || viewModel.isServiceDegraded
        else { return false }
        return !viewModel.displayConnections.isEmpty
    }

    // MARK: Connections

    private var sectionPhaseKey: Int {
        viewModel.departureAnchor == nil ? viewModel.connections.phaseKey : 10 + viewModel.anchoredConnections.phaseKey
    }

    private func rowIds(liveRows: LiveConnectionRows, anchoredRows: [DisplayConnection]) -> [String] {
        guard viewModel.departureAnchor == nil else { return anchoredRows.map(\.id) }
        let passedIds = isPassedSectionExpanded ? liveRows.passed.map(\.id) : []
        return passedIds + liveRows.upcoming.map(\.id)
    }

    @ViewBuilder private func connectionsSection(
        liveRows: LiveConnectionRows,
        anchoredRows: [DisplayConnection]
    ) -> some View {
        if let anchor = viewModel.departureAnchor {
            anchoredSection(anchor: anchor, rows: anchoredRows)
        } else {
            liveSection(rows: liveRows)
        }
    }

    @ViewBuilder private func liveSection(rows: LiveConnectionRows) -> some View {
        switch viewModel.connections {
        case .idle:
            if startStation == nil || endStation == nil {
                EmptyStateView(
                    icon: "tram.fill", title: "Select Your Route",
                    message: "Tap the stations above to choose your start and destination"
                ).frame(maxWidth: .infinity).padding(.top, 40).transition(.opacity)
            } else if !isRouteValid {
                EmptyStateView(
                    icon: "arrow.left.arrow.right", title: "Pick two different stations",
                    message: "Start and destination are the same station",
                    action: { showEndPicker = true }, actionTitle: "Change destination"
                ).frame(maxWidth: .infinity).padding(.top, 40).transition(.opacity)
            }
        case .loading:
            ConnectionsLoadingView(startedAt: viewModel.loadingStartedAt ?? Date()).padding(.top, 8)
                .transition(.opacity)
        case .loaded:
            if viewModel.displayConnections.isEmpty {
                liveEmptyState.frame(maxWidth: .infinity).padding(.top, 40).transition(.opacity)
            } else {
                liveRowsContent(rows)
            }
        case let .error(error):
            ErrorView(error: error) { Task { await viewModel.refreshConnections(isUserInitiated: true) } }
                .frame(maxWidth: .infinity).padding(.top, 40).transition(.opacity)
        }
    }

    @ViewBuilder private var liveEmptyState: some View {
        let types = viewModel.availableTrainTypes
        let excluded = viewModel.config.excludedTrainTypes
        if !types.isEmpty, types.allSatisfy({ excluded.contains($0) }) {
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle", title: "All train types are hidden",
                message: "Turn a train type back on to see departures",
                action: { setExcludedTrainTypes([]) }, actionTitle: "Show all"
            )
        } else if viewModel.displayConnections.isEmpty, let error = viewModel.lastRefreshError {
            ErrorView(error: error) { Task { await viewModel.refreshConnections(isUserInitiated: true) } }
        } else {
            EmptyStateView(
                icon: "tram.fill.tunnel", title: "No Connections",
                message: "No upcoming connections found for this route",
                action: { Task { await viewModel.refreshConnections(isUserInitiated: true) } }, actionTitle: "Refresh"
            )
        }
    }

    @ViewBuilder private func liveRowsContent(_ rows: LiveConnectionRows) -> some View {
        if rows.upcoming.isEmpty, rows.passed.isEmpty, pinnedConnectionId != nil {
            // All connections filtered out because one is pinned
            Text("Other connections").font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(
                maxWidth: .infinity, alignment: .leading
            )
        }

        if !rows.passed.isEmpty {
            passedSectionToggle(count: rows.passed.count)

            if isPassedSectionExpanded {
                ForEach(rows.passed) { displayConnection in
                    connectionRow(displayConnection, showsFullCard: true)
                }
            }
        }

        let firstUpcomingId = rows.upcoming.first?.id
        ForEach(rows.upcoming) { displayConnection in
            connectionRow(
                displayConnection,
                showsFullCard: displayConnection.id == firstUpcomingId
                    || displayConnection.isWithinLeaveCountdownWindow
                    || expandedConnectionIds.contains(displayConnection.id)
            )
        }

        if viewModel.isLoadingMore {
            SkeletonLoadingView(count: 1).transition(.opacity)
        } else if rows.upcomingTotalCount >= viewModel.config.displayMaxConnections {
            EndOfListFooter(count: rows.upcoming.count)
        } else {
            BottomScrollSentinel(
                onScrollPastEnd: { Task { await viewModel.loadMoreConnections() } },
                isLoading: viewModel.isLoadingMore
            )
        }
    }

    private func passedSectionToggle(count: Int) -> some View {
        Button {
            withAnimation(toggleAnimation) {
                isPassedSectionExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Text("Leave window passed (\(count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: isPassedSectionExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isPassedSectionExpanded ? "Expanded" : "Collapsed")
    }

    @ViewBuilder private func anchoredSection(anchor: Date, rows: [DisplayConnection]) -> some View {
        NextLiveTrainBanner(nextLiveConnection: viewModel.nextLiveConnection, anchor: anchor, onBackToNow: returnToNow)

        switch viewModel.anchoredConnections {
        case .idle, .loading:
            SkeletonLoadingView(count: 3).transition(.opacity)
        case .loaded:
            if rows.isEmpty {
                EmptyStateView(
                    icon: "clock.badge.questionmark", title: "No trains found",
                    message: "Nothing leaves after \(RouteHeader.departureChipTitle(for: anchor)) on this route",
                    action: returnToNow, actionTitle: "Back to now"
                ).frame(maxWidth: .infinity).padding(.top, 24).transition(.opacity)
            } else {
                ForEach(rows) { displayConnection in
                    connectionRow(displayConnection, showsFullCard: expandedConnectionIds.contains(displayConnection.id))
                }

                if viewModel.isLoadingMoreAnchored {
                    SkeletonLoadingView(count: 1).transition(.opacity)
                } else if viewModel.anchoredReachedEnd {
                    Text("End of results")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    // A new id per page re-arms the sentinel after a load that ran while the first fetch was still going.
                    BottomScrollSentinel(
                        onScrollPastEnd: { Task { await viewModel.loadMoreAnchored() } },
                        isLoading: viewModel.isLoadingMoreAnchored || jumpsInFlight > 0
                    )
                    .id(rows.count)
                }
            }
        case let .error(error):
            ErrorView(error: error) { Task { await runTrackingJump { await viewModel.rerunJump() } } }
                .frame(maxWidth: .infinity).padding(.top, 24).transition(.opacity)
        }
    }

    @ViewBuilder private func connectionRow(_ displayConnection: DisplayConnection, showsFullCard: Bool) -> some View {
        let isHighlighted = highlightConnectionId == displayConnection.id
        if showsFullCard {
            fullConnectionCard(displayConnection)
                .overlay {
                    if isHighlighted {
                        DeepLinkHighlightRing(cornerRadius: displayConnection.isLeaveWindowPassed ? 12 : 16)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isHighlighted)
                .id(displayConnection.id)
                .transition(.opacity)
        } else {
            CompactConnectionRow(displayConnection: displayConnection, isReminderSet: displayConnection.isSelected) {
                Haptics.selection()
                withAnimation(toggleAnimation) { _ = expandedConnectionIds.insert(displayConnection.id) }
            }
            .overlay {
                if isHighlighted { DeepLinkHighlightRing(cornerRadius: 12) }
            }
            .animation(.easeInOut(duration: 0.3), value: isHighlighted)
            .id(displayConnection.id)
            .transition(.opacity)
        }
    }

    private func fullConnectionCard(_ displayConnection: DisplayConnection) -> some View {
        ConnectionCard(
            displayConnection: displayConnection,
            onSchedule: { Task { await viewModel.scheduleNotification(for: displayConnection.connection) } },
            onCancel: { viewModel.cancelNotification(for: displayConnection.connection) },
            onPin: { setPinned(true, connection: displayConnection.connection) },
            onUnpin: { setPinned(false, connection: displayConnection.connection) },
            onTap: {
                Haptics.selection()
                detailConnection = displayConnection
            }
        )
    }

    private func myJourneyCard(for pinnedJourney: PinnedJourney) -> some View {
        let travel = viewModel.config.travelTime(for: pinnedJourney.departureStation.id)
            ?? viewModel.config.walkingTimeMinutes
        let buffer = viewModel.config.bufferTime(for: pinnedJourney.departureStation.id)
            ?? viewModel.config.bufferTimeMinutes
        let effectiveDeparture = viewModel.config.effectiveDepartureTime(
            baseDepartureTime: pinnedJourney.departureTime,
            delayMinutes: pinnedJourney.delay,
            realtimeDepartureHint: pinnedJourney.legs.first(where: { !$0.isWalking })?.departureTime
        )
        let pinnedLeaveTime = effectiveDeparture.addingTimeInterval(-TimeInterval((travel + buffer) * 60))
        return MyJourneyCard(
            journey: pinnedJourney,
            onUnpin: {
                withAnimation(pinAnimation) { viewModel.unpinJourney() }
            },
            leaveTime: pinnedLeaveTime
        )
    }

    // MARK: Row data

    /// Live rows split the way the list shows them: passed leave windows apart, upcoming capped.
    private struct LiveConnectionRows {
        let passed: [DisplayConnection]
        let upcoming: [DisplayConnection]
        let upcomingTotalCount: Int
    }

    private func makeLiveConnectionRows() -> LiveConnectionRows {
        // The pinned journey shows in MyJourneyCard; departed trains go at once, passed leave windows stay until departure.
        let pinnedId = pinnedConnectionId
        let visibleConnections = viewModel.displayConnections.filter { $0.connection.id != pinnedId && !$0.hasDeparted }
        let upcomingConnections = visibleConnections
            .filter { !$0.isLeaveWindowPassed }
            .sorted { $0.connection.departureTime < $1.connection.departureTime }
        let passedLeaveWindowConnections = visibleConnections
            .filter(\.isLeaveWindowPassed)
            .sorted { $0.connection.departureTime > $1.connection.departureTime }
        return LiveConnectionRows(
            passed: passedLeaveWindowConnections,
            upcoming: Array(upcomingConnections.prefix(viewModel.config.displayMaxConnections)),
            upcomingTotalCount: upcomingConnections.count
        )
    }

    private var visibleAnchoredRows: [DisplayConnection] {
        let pinnedId = pinnedConnectionId
        return (viewModel.anchoredConnections.value ?? []).filter { $0.id != pinnedId && !$0.hasDeparted }
    }

    /// The freshest copy of a row, so the detail sheet's reminder and pin labels follow taps made inside it.
    private func currentDisplayConnection(id: String) -> DisplayConnection? {
        viewModel.displayConnections.first { $0.id == id }
            ?? viewModel.anchoredConnections.value?.first { $0.id == id }
    }

    private var firstUpcomingLiveConnection: DisplayConnection? {
        makeLiveConnectionRows().upcoming.first
    }

    // MARK: Deep link

    /// Non-nil once the deep-linked train is in the loaded list, which is when scrolling to it can work.
    private var deepLinkScrollTargetId: String? {
        guard let highlightConnectionId,
              viewModel.displayConnections.contains(where: { $0.id == highlightConnectionId })
        else { return nil }
        return highlightConnectionId
    }

    private func scrollToHighlightedConnection(with proxy: ScrollViewProxy) {
        guard let targetId = deepLinkScrollTargetId,
              let target = viewModel.displayConnections.first(where: { $0.id == targetId })
        else { return }
        if viewModel.departureAnchor != nil { viewModel.returnToNow() }
        if target.isLeaveWindowPassed {
            isPassedSectionExpanded = true
        } else {
            expandedConnectionIds.insert(targetId)
        }
        // The next main-actor turn runs after the rows above are laid out, so the lazy stack knows the target.
        Task { @MainActor in
            withAnimation(reduceMotion ? nil : .gleisToggle) { proxy.scrollTo(targetId, anchor: .center) }
        }
    }

    // MARK: Detail sheet

    private func detailSheet(for selected: DisplayConnection) -> some View {
        let current = currentDisplayConnection(id: selected.id) ?? selected
        let isPinned = pinnedConnectionId == selected.id
        return ConnectionDetailSheet(
            connection: current.connection,
            onRemind: {
                if current.isSelected {
                    viewModel.cancelNotification(for: current.connection)
                } else {
                    Task { await viewModel.scheduleNotification(for: current.connection) }
                }
            },
            onPin: { setPinned(!isPinned, connection: current.connection) },
            isReminderSet: current.isSelected,
            isPinned: isPinned,
            leaveTime: current.leaveTime
        )
    }

    // MARK: Actions

    private func setPinned(_ isPinned: Bool, connection: TrainConnection) {
        withAnimation(pinAnimation) {
            if isPinned {
                viewModel.pinJourney(for: connection)
            } else {
                viewModel.unpinJourney()
            }
        }
    }

    private func setExcludedTrainTypes(_ excludedTypes: Set<TrainType>) {
        var config = viewModel.config
        config.excludedTrainTypes = excludedTypes
        settingsManager.updateConfig(config)
    }

    private func returnToNow() {
        withAnimation(toggleAnimation) { viewModel.returnToNow() }
    }

    private func startJump(to anchor: Date, openingFirstDetail: Bool = false) {
        Task { @MainActor in
            await runTrackingJump { await viewModel.jump(to: anchor) }
            if openingFirstDetail { detailConnection = visibleAnchoredRows.first }
        }
    }

    /// Counts the jump so the anchored load-more sentinel waits for the first fetch instead of firing into a no-op.
    private func runTrackingJump(_ jump: () async -> Void) async {
        jumpsInFlight += 1
        await jump()
        jumpsInFlight -= 1
    }

    private func applyDebugLaunchOptionsIfReady() {
        let wantsJump = DebugLaunchOptions.jumpHoursAhead != nil
        guard wantsJump || DebugLaunchOptions.openFirstDetail, !didApplyDebugLaunchOptions,
              isRouteValid, !viewModel.displayConnections.isEmpty
        else { return }
        didApplyDebugLaunchOptions = true
        if let hours = DebugLaunchOptions.jumpHoursAhead {
            startJump(to: Date().addingTimeInterval(hours * 3600), openingFirstDetail: DebugLaunchOptions.openFirstDetail)
        } else {
            detailConnection = firstUpcomingLiveConnection
        }
    }

    private func stationPicker(title: String, selection: Binding<Station?>) -> some View {
        StationPickerSheet(
            title: title, stations: viewModel.stations, recentStations: viewModel.config.recentStations,
            favoriteStations: viewModel.config.favoriteStations,
            searchHandler: { await viewModel.searchStations($0) },
            onToggleFavorite: { settingsManager.toggleFavoriteStation($0) },
            selection: selection
        )
    }

    private func loadSavedStations() {
        startStation = viewModel.config.startStation
        endStation = viewModel.config.endStation
    }

    /// Picks up a route saved elsewhere after the first render, such as the debug launch route.
    private func followSavedRoute() {
        let saved = viewModel.config
        guard saved.startStation?.id != startStation?.id || saved.endStation?.id != endStation?.id else { return }
        startStation = saved.startStation
        endStation = saved.endStation
    }

    private func updateConfig(start: Station?, end: Station?) {
        var config = viewModel.config
        let oldStart = config.startStation
        let oldEnd = config.endStation
        let routeChanged = oldStart?.id != start?.id || oldEnd?.id != end?.id
        let changed = oldStart != start || oldEnd != end
        if changed { viewModel.selectedConnection = nil }
        if routeChanged {
            viewModel.cancelCurrentFetch()
            viewModel.setImmediateRouteTransitionState(start: start, end: end)
            expandedConnectionIds = []
        }
        config.startStation = start
        config.endStation = end
        settingsManager.updateConfig(config)
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

// MARK: - DeepLinkHighlightRing

/// Pulses while the deep-linked row is on screen; a steady ring under Reduce Motion.
private struct DeepLinkHighlightRing: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ring = RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.accentColor, lineWidth: 3)
        Group {
            if reduceMotion {
                ring
            } else {
                ring.phaseAnimator([false, true]) { content, isBright in
                    content.opacity(isBright ? 1 : 0.35)
                } animation: { _ in
                    .easeInOut(duration: 0.8)
                }
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}

// MARK: - DataFreshnessBadge

private struct DataFreshnessBadge: View {
    let isStale: Bool
    let lastUpdated: Date?
    @ScaledMetric(relativeTo: .caption2) private var dotDiameter: CGFloat = 7

    private var tint: Color { isStale ? .orange : .green }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: dotDiameter, height: dotDiameter)
            label
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var label: some View {
        if isStale, let lastUpdated {
            TimelineView(.everyMinute) { context in
                let minutes = max(1, Int(context.date.timeIntervalSince(lastUpdated) / 60))
                Text("Updated \(minutes) min ago")
            }
        } else if isStale {
            Text("Not up to date")
        } else {
            Text("Live")
        }
    }
}

// MARK: - RefreshErrorBanner

/// Names a failed refresh while older trains stay on screen.
private struct RefreshErrorBanner: View {
    let title: String
    let onRetry: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                message
                Spacer(minLength: 8)
                retryButton
            }
            VStack(alignment: .leading, spacing: 8) {
                message
                retryButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private var message: some View {
        Label(title, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var retryButton: some View {
        Button("Try again", action: onRetry)
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

// MARK: - NextLiveTrainBanner

/// Sits above a jumped list and names the train there is still time to catch now.
private struct NextLiveTrainBanner: View {
    let nextLiveConnection: DisplayConnection?
    let anchor: Date
    let onBackToNow: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                summary
                Spacer(minLength: 8)
                backButton
            }
            VStack(alignment: .leading, spacing: 10) {
                summary
                backButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.1)))
        .transition(.opacity)
    }

    @ViewBuilder private var summary: some View {
        Group {
            if let next = nextLiveConnection {
                Text("Next now: \(next.connection.lineNumber), leave ") + Text(next.leaveTime, style: .time)
            } else {
                Text("Showing trains from \(RouteHeader.departureChipTitle(for: anchor))")
            }
        }
        .font(.subheadline.weight(.medium).monospacedDigit())
        .fixedSize(horizontal: false, vertical: true)
    }

    private var backButton: some View {
        Button("Back to now", action: onBackToNow)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }
}

// MARK: - ReminderRecoveryBanner

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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: recovery.kind == .missingSelection ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.orange)
                Text(recovery.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Text(recovery.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder private var actionButtons: some View {
        Button(actionTitle, action: onApply)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        Button("Dismiss", action: onDismiss)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

#Preview {
    NavigationStack {
        TransportView().environmentObject(SettingsManager.shared)
    }
}
