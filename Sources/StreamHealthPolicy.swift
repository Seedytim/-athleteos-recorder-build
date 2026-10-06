import Foundation

/// Pure stream-health decisions kept separate from Polar SDK code so recovery
/// behaviour can be regression-tested on every release.
struct StreamHealthPolicy {
    static let startupGraceSeconds: TimeInterval = 15
    static let staleAfterSeconds: TimeInterval = 10

    static func staleChannels(
        expectedChannels: Set<String>,
        lastPacketAt: [String: Date],
        attemptStartedAt: Date,
        now: Date,
        startupGraceSeconds: TimeInterval = StreamHealthPolicy.startupGraceSeconds,
        staleAfterSeconds: TimeInterval = StreamHealthPolicy.staleAfterSeconds
    ) -> [String] {
        expectedChannels.sorted().filter { channel in
            if let lastPacket = lastPacketAt[channel] {
                return now.timeIntervalSince(lastPacket) > staleAfterSeconds
            }
            return now.timeIntervalSince(attemptStartedAt) > startupGraceSeconds
        }
    }

    static func recoveryConfirmed(
        expectedChannels: Set<String>,
        lastPacketAt: [String: Date],
        attemptStartedAt: Date
    ) -> Bool {
        guard !expectedChannels.isEmpty else { return false }
        return expectedChannels.allSatisfy { channel in
            guard let receivedAt = lastPacketAt[channel] else { return false }
            return receivedAt >= attemptStartedAt
        }
    }

    static func shouldRecoverAfterTermination(
        captureExpected: Bool,
        recordingOngoing: Bool,
        taskCancelled: Bool
    ) -> Bool {
        captureExpected && recordingOngoing && !taskCancelled
    }
}
