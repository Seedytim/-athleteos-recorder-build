import SwiftUI

@main
struct AthleteOSRecorderApp: App {
    @StateObject private var recorder = RawH10Capture()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
        }
    }
}
