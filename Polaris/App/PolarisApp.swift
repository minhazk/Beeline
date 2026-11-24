import SwiftUI
import UserNotifications

@main
struct PolarisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var places = PlaceStore()
    @State private var location = LocationService()

    init() {
        Keychain.migrateAccessibility()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        UNUserNotificationCenter.current().setNotificationCategories([TripAlerts.offerActions])
        // A trip Polaris was closed during: picked up again, or cleared away, before any view is up.
        #if DEBUG
        TripResume.decide(skip: Demo.isOn)
        #else
        TripResume.decide()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(places)
                .environment(location)
                .environment(AlertStore.shared)
                .tint(Theme.tint)
                .task { AlertStore.shared.resume() }
        }
    }
}
