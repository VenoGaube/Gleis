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
    @State private var trainScrollToTopTrigger = 0
    @State private var repeatScrollToTopTrigger = 0
    @State private var settingsScrollToTopTrigger = 0

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
                    TransportView(
                        transportType: .trainCommute, highlightConnectionId: deepLinkConnectionId,
                        scrollToTopTrigger: trainScrollToTopTrigger
                    )
                }
                .tag(0)

                NavigationStack(path: $repeatPath) {
                    CommuteScheduleView(
                        viewModel: commuteViewModel,
                        scrollToTopTrigger: repeatScrollToTopTrigger
                    )
                }
                    .tag(1)

                NavigationStack(path: $settingsPath) { SettingsView(scrollToTopTrigger: settingsScrollToTopTrigger) }
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
                    case 0: popToRootThenScrollToTop($trainPath, $trainScrollToTopTrigger)
                    case 1: popToRootThenScrollToTop($repeatPath, $repeatScrollToTopTrigger)
                    case 2: popToRootThenScrollToTop($settingsPath, $settingsScrollToTopTrigger)
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
        }.onAppear { if !settingsManager.appSettings.hasCompletedOnboarding { showOnboarding = true } }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(settingsManager)
                .onDisappear {
                    var settings = settingsManager.appSettings
                    settings.hasCompletedOnboarding = true
                    settingsManager.updateAppSettings(settings)
                }
        }
    }

    // When a pushed screen is popped, wait for the pop before scrolling.
    private func popToRootThenScrollToTop(_ path: Binding<NavigationPath>, _ trigger: Binding<Int>) {
        let hadNavigationDepth = !path.wrappedValue.isEmpty
        path.wrappedValue = NavigationPath()
        if hadNavigationDepth {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { trigger.wrappedValue += 1 }
        } else {
            trigger.wrappedValue += 1
        }
    }
}

#Preview { ContentView().environmentObject(SettingsManager.shared) }
