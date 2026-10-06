import SwiftUI

@main
struct AthleteOSRecorderApp: App {
    @StateObject private var recorder = PolarH10Recorder()
    @StateObject private var uploader = AthleteOSUploader()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(uploader)
        }
    }
}
