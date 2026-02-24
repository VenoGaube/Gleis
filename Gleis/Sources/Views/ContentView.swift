import SwiftUI

struct ContentView: View {
    @Binding var selectedTab: Int
    @Binding var deepLinkConnectionId: String?
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var commuteViewModel = CommuteScheduleViewModel(transportType: .trainCommute)
    @State private var showOnboarding = false
    @State private var didPrewarmRepeatTab = false
    @State private var trainPath = NavigationPath()
    @State private var repeatPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    private let tabs: [TabItem] = [
        TabItem(id: 0, title: "Train", icon: "tram", selectedIcon: "tram.fill"),
        TabItem(id: 1, title: "Repeat", icon: "repeat", selectedIcon: "repeat"),
        TabItem(id: 2, title: "Settings", icon: "gearshape", selectedIcon: "gearshape.fill"),
    ]

    init(selectedTab: Binding<Int> = .constant(0), deepLinkConnectionId: Binding<String?> = .constant(nil)) {
        _selectedTab = selectedTab
        _deepLinkConnectionId = deepLinkConnectionId
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content with swipe navigation using Apple's TabView
            TabView(selection: $selectedTab) {
                NavigationStack(path: $trainPath) {
                    TransportView(transportType: .trainCommute, highlightConnectionId: deepLinkConnectionId)
                }
                .tag(0)

                NavigationStack(path: $repeatPath) { CommuteScheduleView(viewModel: commuteViewModel) }
                    .tag(1)

                NavigationStack(path: $settingsPath) { SettingsView() }
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Custom tab bar
            CustomTabBar(
                selectedTab: $selectedTab, tabs: tabs, accentColor: .trainBlue
            ) { tappedTab in
                // Pop to root if tapping current tab
                if tappedTab == selectedTab {
                    switch tappedTab {
                    case 0: trainPath = NavigationPath()
                    case 1: repeatPath = NavigationPath()
                    case 2: settingsPath = NavigationPath()
                    default: break
                    }
                }
            }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .tint(.trainBlue)
        .environmentObject(settingsManager)
        .task(priority: .utility) {
            guard !didPrewarmRepeatTab else { return }
            didPrewarmRepeatTab = true
            commuteViewModel.onAppear()
            await commuteViewModel.loadStationsIfNeeded()
        }.onAppear { if !settingsManager.appSettings.hasCompletedOnboarding { showOnboarding = true } }.onChange(
            of: deepLinkConnectionId
        ) { _, newValue in
            if newValue != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { deepLinkConnectionId = nil } }
        }.fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(settingsManager)
                .onDisappear {
                    var settings = settingsManager.appSettings
                    settings.hasCompletedOnboarding = true
                    settingsManager.updateAppSettings(settings)
                }
        }
    }
}

#Preview { ContentView().environmentObject(SettingsManager.shared) }
