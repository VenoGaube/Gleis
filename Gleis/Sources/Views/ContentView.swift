import SwiftUI

struct ContentView: View {
    @Binding var selectedTab: Int
    @Binding var deepLinkConnectionId: String?
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var locationService = LocationService.shared
    @State private var showOnboarding = false
    @State private var trainPath = NavigationPath()
    @State private var repeatPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    private let tabs: [TabItem] = [
        TabItem(id: 0, title: "Train", icon: "tram", selectedIcon: "tram.fill"),
        TabItem(id: 1, title: "Repeat", icon: "repeat", selectedIcon: "repeat"),
        TabItem(id: 2, title: "Settings", icon: "gearshape", selectedIcon: "gearshape.fill")
    ]

    init(selectedTab: Binding<Int> = .constant(0), deepLinkConnectionId: Binding<String?> = .constant(nil)) {
        _selectedTab = selectedTab
        _deepLinkConnectionId = deepLinkConnectionId
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content with swipe navigation
            SwipeableTabView(selectedTab: $selectedTab, tabCount: tabs.count) {
                NavigationStack(path: $trainPath) {
                    TransportView(transportType: .trainCommute, highlightConnectionId: deepLinkConnectionId)
                }

                NavigationStack(path: $repeatPath) {
                    CommuteScheduleView()
                }

                NavigationStack(path: $settingsPath) {
                    SettingsView()
                }
            }

            // Custom tab bar
            CustomTabBar(
                selectedTab: $selectedTab,
                tabs: tabs,
                accentColor: .trainBlue,
                onTabTap: { tappedTab in
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
            )
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .tint(.trainBlue)
        .environmentObject(settingsManager)
        .environmentObject(locationService)
        .onAppear {
            if !settingsManager.appSettings.hasCompletedOnboarding { showOnboarding = true }
        }
        .onChange(of: deepLinkConnectionId) { _, newValue in
            if newValue != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { deepLinkConnectionId = nil } }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding).onDisappear {
                var settings = settingsManager.appSettings
                settings.hasCompletedOnboarding = true
                settingsManager.updateAppSettings(settings)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(LocationService.shared)
}
