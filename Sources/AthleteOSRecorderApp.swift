import SwiftUI

@main
struct AthleteOSRecorderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = PolarH10Recorder()
    @StateObject private var uploader = AthleteOSUploader()

    @StateObject private var notifications = RecorderNotifications()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(uploader)
                .environmentObject(notifications)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        recorder.appBecameActive()
                    case .background:
                        recorder.appEnteredBackground()
                    default:
                        break
                    }
                }
        }
    }
}
