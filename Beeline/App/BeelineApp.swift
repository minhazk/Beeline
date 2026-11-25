import SwiftUI
import UserNotifications

@main
struct BeelineApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var places = PlaceStore()
    @State private var location = LocationService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Keychain.migrateAccessibility()
        // Earlier builds kept a contact address typed in Settings; nothing reads it any more. It was
        // also a sign this isn't a new install, which the first-run page still needs to know.
        if Keychain.get("contact") != nil {
            UserDefaults.standard.set(true, forKey: FirstRun.seenKey)
            Keychain.set("", for: "contact")
        }
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        UNUserNotificationCenter.current().setNotificationCategories([TripAlerts.offerActions])
        // A trip Beeline was closed during: picked up again, or cleared away, before any view is up.
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
                .task {
                    AlertStore.shared.resume()
                    #if DEBUG
                    if Demo.showsNextTrain { await Demo.startNextTrain() }
                    #endif
                }
                // Notifications turned off or on in Settings while Beeline waited in the
                // background: the server's copy follows as soon as it's back in front.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await AlertStore.shared.refreshPermission() } }
                }
        }
    }
}
