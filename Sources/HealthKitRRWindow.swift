import Foundation

/// Deliberately narrow compatibility test: one recent, uninterrupted, approximately
/// five-minute H10 live RR window. Never infer missing beats across BLE gaps.
struct HealthKitRRWindow: Sendable {
    let start: Date
    let end: Date
    let intervalsMs: [Int]
    let sdnnMs: Double
    let rmssdMs: Double

    var durationSeconds: Double { intervalsMs.reduce(0.0) { $0 + Double($1) / 1_000 } }

    static func latestFiveMinutes(in recording: RawH10RRRecording) -> HealthKitRRWindow? {
        guard recording.storageMode == "phone_live", let packets = recording.rrPackets else { return nil }

        let ordered = packets.enumerated().sorted {
            let a = $0.element.receivedAtUnixMs ?? ($0.element.receivedAt.timeIntervalSince1970 * 1_000)
            let b = $1.element.receivedAtUnixMs ?? ($1.element.receivedAt.timeIntervalSince1970 * 1_000)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)

        var run: [Int] = []
        var lastReceipt: Double?
        var lastSegment: UUID?
        var runEnd: Date?
        var best: HealthKitRRWindow?

        func evaluate() {
            guard let end = runEnd else { return }
            var slice: [Int] = []
            var seconds = 0.0
            for rr in run.reversed() {
                slice.append(rr)
                seconds += Double(rr) / 1_000
                if seconds >= 300 { break }
            }
            guard seconds >= 300, slice.count >= 150 else { return }
            slice.reverse()
            let values = slice.map(Double.init)
            let mean = values.reduce(0, +) / Double(values.count)
            let sdnn = sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1))
            let rmssd = sqrt(zip(values.dropFirst(), values).reduce(0.0) {
                $0 + pow($1.0 - $1.1, 2)
            } / Double(values.count - 1))
            let candidate = HealthKitRRWindow(
                start: end.addingTimeInterval(-seconds), end: end,
                intervalsMs: slice, sdnnMs: sdnn, rmssdMs: rmssd
            )
            if best == nil || end > best!.end { best = candidate }
        }

        for packet in ordered {
            let receipt = (packet.receivedAtUnixMs ?? packet.receivedAt.timeIntervalSince1970 * 1_000) / 1_000
            let rr = packet.rrMs
            let valid = packet.rrAvailable && (!packet.contactStatusSupported || packet.contactStatus)
                && !rr.isEmpty && rr.allSatisfy { (300...2_000).contains($0) }
            guard valid else {
                evaluate()
                run.removeAll(keepingCapacity: true)
                lastReceipt = nil
                lastSegment = nil
                runEnd = nil
                continue
            }

            let packetDuration = Double(rr.reduce(0, +)) / 1_000
            if let previous = lastReceipt {
                // Notification receipt is NOT a hardware clock. This generous tolerance
                // only detects clear loss/reset; it does not invent missing heartbeat times.
                let isSameSegment = lastSegment == packet.streamSegmentId
                let observed = receipt - previous
                if !isSameSegment || observed < -0.001 || abs(observed - packetDuration) > 2.5 {
                    evaluate()
                    run.removeAll(keepingCapacity: true)
                }
            }
            run.append(contentsOf: rr)
            lastReceipt = receipt
            lastSegment = packet.streamSegmentId
            runEnd = Date(timeIntervalSince1970: receipt)
        }
        evaluate()
        return best
    }
}
