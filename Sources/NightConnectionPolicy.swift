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


enum NightOperation: Equatable { case start, end, archiveSaved }

enum NightActionPolicy {
    static func afterRecovery(requestedEnd: Bool, recordingOngoing: Bool, pendingFetch: Bool) -> NightOperation {
        if recordingOngoing || pendingFetch { return .end }
        return requestedEnd ? .archiveSaved : .start
    }
}
