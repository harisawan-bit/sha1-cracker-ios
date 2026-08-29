import SwiftUI

@main
struct SHA1CrackerApp: App {
    init() {
        // Keep device display awake during cracking operations
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
