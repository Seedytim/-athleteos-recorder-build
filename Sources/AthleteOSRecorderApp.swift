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
                .onOpenURL { url in
                    Task {
                        guard await uploader.handleConnectionURL(url) else { return }
                        // ContentView owns the durable pending-file queue. Once
                        // connected, its connection observer archives every saved file
                        // and only deletes local data after a verified SHA receipt.
                    }
                }
        }
    }
}
