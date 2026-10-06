import Foundation

enum NightConnectionStep: Equatable {
    case wait, ready, reconnect, failed
}

/// Shared by the real connection loop and deterministic transition tests.
enum NightConnectionPolicy {
    static func next(bluetoothOn: Bool, connected: Bool, recordingReady: Bool,
                     transferReady: Bool, transportBusy: Bool, preparationTimedOut: Bool,
                     deadlineReached: Bool, attempt: Int) -> NightConnectionStep {
        guard bluetoothOn else { return .failed }
        if connected && recordingReady && transferReady && !transportBusy { return .ready }
        if preparationTimedOut || deadlineReached { return attempt == 0 ? .reconnect : .failed }
        return .wait
    }
}


/// Stored-file reads need PS-FTP, but they do not need the H10 exercise-recording
/// service to advertise readiness again after the recording has already stopped.
/// Keeping this separate prevents a healthy file-transfer session being rejected
/// just because the recording-service callback is late or absent.
enum StoredFetchConnectionPolicy {
    static func ready(connected: Bool, transferReady: Bool) -> Bool {
        connected && transferReady
    }
}


enum NightOperation: Equatable { case start, end, archiveSaved }

enum NightActionPolicy {
    static func afterRecovery(requestedEnd: Bool, recordingOngoing: Bool, pendingFetch: Bool) -> NightOperation {
        if recordingOngoing || pendingFetch { return .end }
        return requestedEnd ? .archiveSaved : .start
    }
}
