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
                        if let file = recorder.lastSavedFile, !recorder.athleteOSUploadConfirmed {
                            if await uploader.upload(fileURL: file) {
                                recorder.markAthleteOSUploadConfirmed(for: file)
                            }
                        }
                    }
                }
        }
    }
}
