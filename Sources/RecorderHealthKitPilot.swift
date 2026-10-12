import Foundation
import HealthKit
import SwiftUI

/// One-shot, opt-in compatibility pilot; not the AthleteOS recovery pipeline.
@MainActor
final class RecorderHealthKitPilot: ObservableObject {
    @Published private(set) var statusText =
        UserDefaults.standard.string(forKey: "healthkit.lastPilotResult")
        ?? "Not tested. Arm one export, record at least five continuous minutes, then End night."

    private let healthStore = HKHealthStore()
    private let historyKey = "healthkit.pilotExportedRecordingIds"

    func exportFiveMinuteWindow(fileURL: URL) async {
        do {
            guard HKHealthStore.isHealthDataAvailable() else {
                throw PilotError.message("Apple Health is unavailable on this device.")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let recording = try decoder.decode(RawH10RRRecording.self, from: Data(contentsOf: fileURL))
            let prior = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
            guard !prior.contains(recording.id.uuidString) else {
                throw PilotError.message("This recording was already exported. No duplicate created.")
            }
            guard let window = HealthKitRRWindow.latestFiveMinutes(in: recording) else {
                throw PilotError.message("No continuous five-minute RR window passed basic contact and gap checks. Nothing was written.")
            }

            let heartbeats = HKSeriesType.heartbeat()
            let sdnnType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
            try await healthStore.requestAuthorization(toShare: [heartbeats, sdnnType], read: [])
            guard healthStore.authorizationStatus(for: heartbeats) == .sharingAuthorized,
                  healthStore.authorizationStatus(for: sdnnType) == .sharingAuthorized else {
                throw PilotError.message("Apple Health write permission was not granted. Nothing was written.")
            }

            let device = HKDevice(
                name: "Polar H10", manufacturer: "Polar", model: "H10",
                hardwareVersion: nil, firmwareVersion: recording.firmwareVersion,
                softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil
            )
            let builder = HKHeartbeatSeriesBuilder(healthStore: healthStore, device: device, start: window.start)
            let syncBase = "athleteos.h10.pilot.\(recording.id.uuidString.lowercased())"
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                builder.addMetadata([
                    HKMetadataKeySyncIdentifier: syncBase + ".beats",
                    HKMetadataKeySyncVersion: 1,
                    "athleteos.timestampMethod": "host_BLE_notification_receipt_estimate",
                ]) { success, error in
                    if success { continuation.resume() }
                    else { continuation.resume(throwing: error ?? PilotError.message("Heartbeat metadata failed.")) }
                }
            }

            var elapsed = 0.0
            for (index, rr) in window.intervalsMs.enumerated() {
                elapsed += Double(rr) / 1_000
                let offset = elapsed
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    builder.addHeartbeatWithTimeInterval(sinceSeriesStartDate: offset, precededByGap: index == 0) { success, error in
                        if success { continuation.resume() }
                        else { continuation.resume(throwing: error ?? PilotError.message("Heartbeat series write failed.")) }
                    }
                }
            }
            let series = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKHeartbeatSeriesSample, Error>) in
                builder.finishSeries { sample, error in
                    if let sample { continuation.resume(returning: sample) }
                    else { continuation.resume(throwing: error ?? PilotError.message("HealthKit returned no heartbeat series.")) }
                }
            }

            // RMSSD is intentionally NOT written into SDNN. Athlytic must independently
            // demonstrate whether it reads our third-party heartbeat series.
            let sdnn = HKQuantitySample(
                type: sdnnType,
                quantity: HKQuantity(unit: HKUnit.secondUnit(with: .milli), doubleValue: window.sdnnMs),
                start: window.start,
                end: window.end,
                device: device,
                metadata: [
                    HKMetadataKeySyncIdentifier: syncBase + ".sdnn",
                    HKMetadataKeySyncVersion: 1,
                    "athleteos.timestampMethod": "host_BLE_notification_receipt_estimate",
                ]
            )
            do {
                try await healthStore.save(sdnn)
            } catch {
                // Avoid leaving only half of the pilot output in HealthKit.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    healthStore.delete(series) { _, _ in continuation.resume() }
                }
                throw error
            }
            UserDefaults.standard.set(Array((prior + [recording.id.uuidString]).suffix(64)), forKey: historyKey)
            setStatus("Health export saved: 5-min H10 heartbeat series + SDNN (\(Int(window.sdnnMs.rounded())) ms). Compare Athlytic RMSSD ON/OFF. Raw timestamps are approximate.")
        } catch {
            setStatus("Health export test: \(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) {
        statusText = text
        UserDefaults.standard.set(text, forKey: "healthkit.lastPilotResult")
    }

    private enum PilotError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
}
