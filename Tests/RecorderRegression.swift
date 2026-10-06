import Foundation

@main
struct RecorderRegression {
    static func main() async throws {
        testConnectionTransitions()
        try testMorningSaveSourceInvariants()
        testStreamHealthPolicy()
        let id = UUID().uuidString
        let sha = String(repeating: "a", count: 64)
        func receipt(archived: Bool = true, verified: Bool = true, hash: String? = nil, processing: String = "complete") -> Data {
            Data("{\"ok\":true,\"archived\":\(archived),\"archive\":{\"verified\":\(verified),\"recording_id\":\"\(id)\",\"sha256\":\"\(hash ?? sha)\"},\"processing\":{\"state\":\"\(processing)\"}}".utf8)
        }
        precondition(UploadReceipt.verifiedArchive(in: receipt(), expectedSHA256: sha)?.recordingID == id)
        precondition(UploadReceipt.verifiedArchive(in: receipt(processing: "insufficient_data"), expectedSHA256: sha)?.recordingID == id)
        precondition(UploadReceipt.verifiedArchive(in: receipt(processing: "error"), expectedSHA256: sha)?.recordingID == id)
        precondition(UploadReceipt.verifiedArchive(in: receipt(processing: "pending"), expectedSHA256: sha)?.recordingID == id)
        precondition(UploadReceipt.verifiedArchive(in: receipt(hash: "bad"), expectedSHA256: "bad") == nil)
        precondition(UploadReceipt.verifiedArchive(in: receipt(archived: false), expectedSHA256: sha) == nil)
        precondition(UploadReceipt.verifiedArchive(in: receipt(verified: false), expectedSHA256: sha) == nil)
        precondition(UploadReceipt.verifiedArchive(in: receipt(hash: String(repeating: "b", count: 64)), expectedSHA256: sha) == nil)
        precondition(UploadReceipt.verifiedArchive(in: Data("{\"ok\":true}".utf8), expectedSHA256: sha) == nil)
        precondition(UploadReceipt.verifiedArchive(in: Data("not json".utf8), expectedSHA256: sha) == nil)
        let samples: [UInt32] = [800, 810, 0, 2001, 795]
        let raw = RawH10RRRecording(deviceId: "TEST", exerciseId: "fixture", startedAt: Date(), stoppedAt: Date(), fetchedAt: Date(), polarSdkVersion: "test", firmwareVersion: "test", batteryPercentAtFetch: 80, recordingIntervalSeconds: 1, rrSamplesRaw: samples)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root, digest: { _ in sha })
        let url = try await store.save(raw)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(RawH10RRRecording.self, from: Data(contentsOf: url))
        precondition(saved.rrSamplesRaw == samples, "Raw RR must remain unchanged, including outliers")
        let files = try await store.list()
        precondition(files.contains { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }, "Saved files must remain discoverable")
        let savedExerciseId = try await store.exerciseId(for: url)
        precondition(savedExerciseId == "fixture", "Saved file must retain its sensor exercise identity")
        try await store.delete(url)
        precondition(!FileManager.default.fileExists(atPath: url.path), "Verified local cleanup must remove only the selected file")
        try await testCleanupJournal(raw: raw, sha: sha, id: id)
        try await testResearchCaptureStore()
        try await testEpisodeCaptureIsolation()
        #if canImport(Combine) && canImport(Security) && canImport(CryptoKit)
        try await testUploaderTransport(raw: raw)
        #endif
        print("PASS: verified archive receipts only, SHA must match, raw samples preserved, queue files discoverable and independently deletable")
    }

    static func testEpisodeCaptureIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchCaptureStore(root: root)
        func metadata(_ exercise: String, device: String = "H10") -> ResearchDeviceMetadata {
            ResearchDeviceMetadata(deviceId: device, model: "Polar H10", firmwareVersion: nil,
                polarSdkVersion: "test", appVersion: "2.1.3", appBuild: "20",
                internalRRExerciseId: exercise, batteryPercentAtStart: 100)
        }
        let origin = Date(timeIntervalSince1970: 1000)
        let first = try await store.ensureEpisodeCapture(metadata: metadata("old"), channels: [],
            episodeStartedAt: origin, now: origin.addingTimeInterval(10))
        let resumed = try await store.ensureEpisodeCapture(metadata: metadata("old"), channels: [],
            episodeStartedAt: origin, now: origin.addingTimeInterval(20))
        precondition(first == resumed, "Reconnect must retain matching episode identity")
        let secondStart = origin.addingTimeInterval(100)
        let second = try await store.ensureEpisodeCapture(metadata: metadata("new"), channels: [],
            episodeStartedAt: secondStart, now: secondStart.addingTimeInterval(5))
        precondition(second != first, "New exercise must create a separate capture")
        do {
            try await store.appendECG([ResearchECGSample(deviceTimestampNs: 1, voltageMicrovolts: 42)], captureId: first)
            preconditionFailure("Old stream must not write into new capture")
        } catch ResearchCaptureStore.StoreError.staleCapture {}
        try await store.appendECG([ResearchECGSample(deviceTimestampNs: 2, voltageMicrovolts: 43)], captureId: second)
        _ = try await store.finish(batteryPercentAtEnd: 99, endedAt: secondStart.addingTimeInterval(15))
        let archives = try await store.pendingArchives()
        precondition(archives.count == 2, "Previous raw data must be preserved")
        let latest = archives.first { $0.captureId == second }!
        precondition(latest.manifest.device.internalRRExerciseId == "new")
        precondition(latest.manifest.startedAt == secondStart.addingTimeInterval(5))
        precondition(latest.manifest.episodeStartedAt == secondStart)
        precondition(latest.manifest.files.first { $0.channel == "ecg" }?.recordCount == 1)
        let third = try await store.ensureEpisodeCapture(metadata: metadata("new"), channels: [],
            episodeStartedAt: secondStart, now: secondStart.addingTimeInterval(30))
        let otherDevice = try await store.ensureEpisodeCapture(metadata: metadata("new", device: "OTHER"), channels: [],
            episodeStartedAt: secondStart, now: secondStart.addingTimeInterval(40))
        precondition(third != otherDevice, "Device identity must also match")
        print("PASS: episode isolation, reconnect reuse, segment clock, retained raw data, stale packet rejection")
    }

    static func testStreamHealthPolicy() {
        let start = Date(timeIntervalSince1970: 1_000)
        let expected: Set<String> = ["ecg", "acc"]
        precondition(StreamHealthPolicy.staleChannels(
            expectedChannels: expected,
            lastPacketAt: [:],
            attemptStartedAt: start,
            now: start.addingTimeInterval(14)
        ).isEmpty, "Startup grace must not trigger a premature reconnect")
        precondition(Set(StreamHealthPolicy.staleChannels(
            expectedChannels: expected,
            lastPacketAt: [:],
            attemptStartedAt: start,
            now: start.addingTimeInterval(16)
        )) == expected, "A stream that never produces samples must be restarted")
        precondition(StreamHealthPolicy.staleChannels(
            expectedChannels: expected,
            lastPacketAt: ["ecg": start.addingTimeInterval(15), "acc": start.addingTimeInterval(15)],
            attemptStartedAt: start,
            now: start.addingTimeInterval(24)
        ).isEmpty)
        precondition(StreamHealthPolicy.staleChannels(
            expectedChannels: expected,
            lastPacketAt: ["ecg": start.addingTimeInterval(15), "acc": start.addingTimeInterval(25)],
            attemptStartedAt: start,
            now: start.addingTimeInterval(26)
        ) == ["ecg"], "A silently stalled channel must be identified independently")
        precondition(!StreamHealthPolicy.recoveryConfirmed(
            expectedChannels: expected,
            lastPacketAt: ["ecg": start.addingTimeInterval(1)],
            attemptStartedAt: start
        ), "Task creation or a single channel must not count as recovery")
        precondition(StreamHealthPolicy.recoveryConfirmed(
            expectedChannels: expected,
            lastPacketAt: ["ecg": start.addingTimeInterval(1), "acc": start.addingTimeInterval(2)],
            attemptStartedAt: start
        ), "Every expected PMD channel must deliver a fresh packet")
        precondition(StreamHealthPolicy.shouldRecoverAfterTermination(
            captureExpected: true, recordingOngoing: true, taskCancelled: false
        ), "Normal AsyncSequence completion must trigger recovery")
        precondition(!StreamHealthPolicy.shouldRecoverAfterTermination(
            captureExpected: true, recordingOngoing: true, taskCancelled: true
        ), "Intentional cancellation must not trigger recovery")
        print("PASS: PMD startup grace, silent-stall detection, normal completion recovery, and packet-confirmed restart")
    }
    static func testConnectionTransitions() {
        func step(on: Bool = true, connected: Bool = false, record: Bool = false,
                  transfer: Bool = false, busy: Bool = false, timedOut: Bool = false,
                  deadline: Bool = false, attempt: Int = 0) -> NightConnectionStep {
            NightConnectionPolicy.next(bluetoothOn: on, connected: connected, recordingReady: record,
                transferReady: transfer, transportBusy: busy, preparationTimedOut: timedOut,
                deadlineReached: deadline, attempt: attempt)
        }
        // One press keeps ownership through disconnected -> connected -> services.
        let transitions = [step(), step(connected: true), step(connected: true, record: true),
                           step(connected: true, record: true, transfer: true, busy: true),
                           step(connected: true, record: true, transfer: true)]
        precondition(transitions == [.wait, .wait, .wait, .wait, .ready])
        precondition(step(timedOut: true) == .reconnect)
        precondition(step(deadline: true) == .reconnect)
        precondition(step(timedOut: true, attempt: 1) == .failed)
        precondition(step(deadline: true, attempt: 1) == .failed)
        precondition(step(on: false, connected: true, record: true, transfer: true) == .failed)
        precondition(StoredFetchConnectionPolicy.ready(connected: true, transferReady: true), "Stopped-night fetch needs PS-FTP only")
        precondition(!StoredFetchConnectionPolicy.ready(connected: true, transferReady: false))
        precondition(!StoredFetchConnectionPolicy.ready(connected: false, transferReady: true))
        precondition(NightActionPolicy.afterRecovery(requestedEnd: true, recordingOngoing: false, pendingFetch: false) == .archiveSaved, "Crash-recovered End must never start a new night")
        precondition(NightActionPolicy.afterRecovery(requestedEnd: true, recordingOngoing: false, pendingFetch: true) == .end)
        precondition(NightActionPolicy.afterRecovery(requestedEnd: false, recordingOngoing: false, pendingFetch: false) == .start)
        precondition(NightActionPolicy.afterRecovery(requestedEnd: false, recordingOngoing: true, pendingFetch: false) == .end)
        print("PASS: disconnected connection ownership, both services required, PFTP arbitration, bounded reconnect, Bluetooth loss")
    }

    static func testMorningSaveSourceInvariants() throws {
        let source = try String(contentsOfFile: "Sources/PolarH10Recorder.swift", encoding: .utf8)

        guard let stopStart = source.range(of: "func stopFetchAndSave() async {"),
              let retryStart = source.range(of: "func retryFetchAndSave() async {", range: stopStart.upperBound..<source.endIndex) else {
            preconditionFailure("Morning save functions must remain discoverable")
        }
        let stopBody = String(source[stopStart.lowerBound..<retryStart.lowerBound])
        precondition(stopBody.contains("await fetchAndSaveStoredRecording"),
                     "End night must attempt the stored RR read")
        precondition(!stopBody.contains("try await resetConnectionForStoredFetch()"),
                     "Normal End night must not force a reconnect before its first stored RR read")

        guard let fetchStart = source.range(of: "private func fetchAndSaveStoredRecording"),
              let persistStart = source.range(of: "private func persistFetchedExercise", range: fetchStart.upperBound..<source.endIndex) else {
            preconditionFailure("Stored fetch implementation must remain discoverable")
        }
        let fetchBody = String(source[fetchStart.lowerBound..<persistStart.lowerBound])
        precondition(fetchBody.contains("let maxAttempts = 3"),
                     "Morning fetch retries must stay bounded")
        precondition(fetchBody.contains("fetchExerciseAcrossKnownSessions(directEntry, seconds: 60)"),
                     "Direct H10 RR read must stay on the bounded 60-second path")
        precondition(fetchBody.contains("try await resetConnectionForStoredFetch()"),
                     "Reconnect must remain available as recovery after an actual read failure")
        precondition(fetchBody.contains("isPolarSessionUnavailable(error)"),
                     "Polar SDK session-loss errors must trigger explicit session recovery")
        precondition(fetchBody.contains("recoverMissingSdkSessionForStoredFetch()"),
                     "Stored RR fetch must recover a missing Polar SDK session instead of repeating the same failing call")
        precondition(source.contains("api = Self.makePolarApi()"),
                     "Persistent Polar error 2/3 must rebuild the Polar BLE API instance")
        precondition(source.contains("oldApi.cleanup()"),
                     "Hard session recovery must dispose stale SDK session state")
        precondition(source.contains("Verifying stored-file access"),
                     "Hard recovery must verify real stored-file access before declaring success")
        precondition(source.contains("listExercisesWithTimeout(seconds: 12, identifier: identifier)"),
                     "Hard recovery must prove sessionFtpClientReady through exercise enumeration")
        precondition(source.contains("fetchExerciseAcrossKnownSessions"),
                     "Stored RR read should try both the peripheral UUID and Polar device ID")
        precondition(source.contains("listExercisesAcrossKnownSessions"),
                     "Stored exercise lookup should try both known session identifiers")
        precondition(source.contains(".feature_polar_features_configuration_service"),
                     "Recorder must enable Polar Features Configuration Service for dual-BLE control")
        precondition(source.contains("getMultiBLEConnectionMode(identifier: identifier)"),
                     "Recorder must read and verify H10 multi-BLE mode")
        precondition(source.contains("setMultiBLEConnectionMode(identifier: identifier, enable: false)"),
                     "Recorder must explicitly disable H10 dual-BLE mode")
        precondition(source.contains("enforceSingleBLEConnectionMode(context: \"before overnight recording\")"),
                     "Start night must verify single-BLE mode before creating an offline RR recording")
        precondition(source.contains("enforceSingleBLEConnectionMode(context: \"before retained RR recovery\")"),
                     "Retained-file recovery must verify single-BLE mode before PFTP fetch")
        precondition(source.contains("enforceSingleBLEConnectionMode(context: \"after PFTP retry\")"),
                     "A PFTP 106 retry must reassert single-BLE mode after reconnect")

        precondition(source.contains("sdkSessionIdentifier = identifier.address.uuidString"),
                     "Connected peripheral UUID must be captured for stable SDK session lookup")
        precondition(source.contains("let sensorId = identifier ?? preferredSdkIdentifier"),
                     "Stored-file operations must support explicit session identifiers with UUID preference")
        precondition(source.contains("case .deviceNotConnected, .deviceNotFound:"),
                     "Polar error 2/3 must be classified as session loss")
        precondition(source.contains("try await Task.sleep(for: .seconds(2))"),
                     "Recovered file-transfer sessions need a post-ready settle period")

        guard let resetStart = source.range(of: "private func resetConnectionForStoredFetch() async throws {"),
              let fetchRange = source.range(of: "private func fetchAndSaveStoredRecording", range: resetStart.upperBound..<source.endIndex) else {
            preconditionFailure("Stored reconnect implementation must remain discoverable")
        }
        let resetBody = String(source[resetStart.lowerBound..<fetchRange.lowerBound])
        precondition(resetBody.contains("StoredFetchConnectionPolicy.ready"),
                     "Stopped-file recovery should gate on PS-FTP readiness")
        precondition(!resetBody.contains("connectionState == .connected && h10RecordingFeatureReady && fileTransferFeatureReady"),
                     "Stopped-file recovery must not require the exercise-recording service callback")

        print("PASS: morning save + single-BLE safeguard + dual identifier lookup + hard SDK rebuild + verified PS-FTP recovery")
    }

    static func testCleanupJournal(raw: RawH10RRRecording, sha: String, id: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root, digest: { _ in sha })
        let first = try await store.save(raw)
        let secondRaw = RawH10RRRecording(deviceId: "OTHER_SENSOR", exerciseId: "second", startedAt: nil, stoppedAt: Date(), fetchedAt: Date(), polarSdkVersion: "test", firmwareVersion: nil, batteryPercentAtFetch: nil, recordingIntervalSeconds: 1, rrSamplesRaw: [900, 901])
        let second = try await store.save(secondRaw)
        let restarted = RecordingStore(root: root, digest: { _ in sha })
        let pending = try await restarted.list()
        precondition(pending.count == 2, "App restart must recover all pending raw files")
        // A lost network response has no receipt: no cleanup transaction is performed.
        precondition(FileManager.default.fileExists(atPath: first.path))
        let mismatch = VerifiedArchiveReceipt(recordingID: id, sha256: String(repeating: "b", count: 64), processingState: "error")
        do {
            _ = try await store.confirmArchive(first, receipt: mismatch)
            preconditionFailure("Mismatched SHA must not authorize local deletion")
        } catch RecordingStore.StoreError.archiveMismatch {}
        precondition(FileManager.default.fileExists(atPath: first.path))
        let receipt = VerifiedArchiveReceipt(recordingID: id, sha256: sha, processingState: "error")
        enum FixtureError: Error { case deletionFailed }
        let failingDelete = RecordingStore(root: root, digest: { _ in sha }, removeFile: { _ in throw FixtureError.deletionFailed })
        do {
            _ = try await failingDelete.confirmArchive(first, receipt: receipt)
            preconditionFailure("Injected local deletion failure must propagate")
        } catch FixtureError.deletionFailed {}
        precondition(FileManager.default.fileExists(atPath: first.path), "Local failure retains raw")
        let jobs = try await restarted.readySensorCleanups()
        precondition(jobs.count == 1 && jobs[0].identity.deviceId == raw.deviceId)
        precondition(!FileManager.default.fileExists(atPath: first.path), "Restart finishes verified local cleanup")
        precondition(FileManager.default.fileExists(atPath: second.path), "Cleanup must not delete another pending recording")
        let afterFailedH10Cleanup = try await RecordingStore(root: root, digest: { _ in sha }).readySensorCleanups()
        precondition(afterFailedH10Cleanup.count == 1, "Failed H10 cleanup stays durably queued")
        _ = try await store.confirmArchive(second, receipt: receipt)
        let multiple = try await store.readySensorCleanups()
        precondition(multiple.count == 2 && Set(multiple.map { $0.identity.deviceId }).count == 2)
        try await store.finishSensorCleanup(jobs[0])
        let remaining = try await store.readySensorCleanups()
        precondition(remaining.count == 1 && remaining[0].identity.exerciseId == "second")
        print("PASS: crash journal, multiple pending nights, SHA mismatch, local deletion failure, device-scoped cleanup retry, independent analysis error")
    }

    static func testResearchCaptureStore() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let channel = ResearchChannelDescriptor(
            channel: "ecg",
            source: "Polar H10 PMD",
            sampleRateHz: 130,
            unit: "microvolt",
            recordEncoding: "little_endian:uint64_timestamp_ns,int32_microvolts",
            supportedSettings: ["sample_rate_hz": [130]],
            selectedSettings: ["sample_rate_hz": 130]
        )
        let metadata = ResearchDeviceMetadata(
            deviceId: "TEST-H10",
            model: "Polar H10",
            firmwareVersion: "5.0.0",
            polarSdkVersion: "8.4.0",
            appVersion: "test",
            appBuild: "test",
            internalRRExerciseId: "AOS_TEST",
            batteryPercentAtStart: 90
        )

        let store = ResearchCaptureStore(root: root, chunkLimitBytes: 40)
        let summary = try await store.begin(metadata: metadata, channels: [channel], startedAt: Date(timeIntervalSince1970: 100))
        let ecgA = [
            ResearchECGSample(deviceTimestampNs: 10, voltageMicrovolts: -101),
            ResearchECGSample(deviceTimestampNs: 20, voltageMicrovolts: 202)
        ]
        let ecgB = [
            ResearchECGSample(deviceTimestampNs: 30, voltageMicrovolts: -303),
            ResearchECGSample(deviceTimestampNs: 40, voltageMicrovolts: 404)
        ]
        try await store.appendECG(ecgA)
        try await store.appendECG(ecgB)
        try await store.appendACC([
            ResearchACCSample(deviceTimestampNs: 10, xMilliG: -1, yMilliG: 2, zMilliG: 999)
        ])
        try await store.appendHR([
            ResearchHRSample(
                receivedAt: Date(timeIntervalSince1970: 101),
                bpm: 52,
                rrMs: [1148],
                rrAvailable: true,
                contactStatus: true,
                contactStatusSupported: true
            )
        ])
        try await store.appendEvent(kind: "gap_started", detail: "Bluetooth disconnected during diagnostic test.")

        let captureDir = summary.directory
        let firstECG = captureDir.appendingPathComponent("ecg-0000.bin")
        let secondECG = captureDir.appendingPathComponent("ecg-0001.bin")
        precondition(FileManager.default.fileExists(atPath: firstECG.path))
        precondition(FileManager.default.fileExists(atPath: secondECG.path), "Chunk limit must rotate raw ECG into another durable file")

        let bytes = try Data(contentsOf: firstECG)
        precondition(bytes.count == 24, "Two ECG records use exactly 12 bytes each")
        func u64(_ data: Data, _ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(data[offset + i]) << UInt64(i * 8) }
            return value
        }
        func i32(_ data: Data, _ offset: Int) -> Int32 {
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(data[offset + i]) << UInt32(i * 8) }
            return Int32(bitPattern: value)
        }
        precondition(u64(bytes, 0) == 10 && i32(bytes, 8) == -101)
        precondition(u64(bytes, 12) == 20 && i32(bytes, 20) == 202, "Raw signed ECG values and device timestamps must round-trip exactly")

        // Simulate a process dying in the middle of one binary record.
        let partial = captureDir.appendingPathComponent("acc-0000.bin")
        let partialHandle = try FileHandle(forWritingTo: partial)
        try partialHandle.seekToEnd()
        try partialHandle.write(contentsOf: Data([0xAA, 0xBB, 0xCC]))
        try partialHandle.close()

        let restarted = ResearchCaptureStore(root: root, chunkLimitBytes: 40)
        let recoveredCount = try await restarted.recoverInterruptedCaptures(now: Date(timeIntervalSince1970: 200))
        precondition(recoveredCount == 1, "An app interruption must be discovered without deleting raw chunks")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            ResearchCaptureManifest.self,
            from: Data(contentsOf: captureDir.appendingPathComponent("manifest.json"))
        )
        precondition(manifest.state == "interrupted")
        precondition(manifest.rawValuePolicy.contains("preserved unchanged"))
        precondition(FileManager.default.fileExists(atPath: firstECG.path) && FileManager.default.fileExists(atPath: secondECG.path))

        let events = try String(contentsOf: captureDir.appendingPathComponent("events.ndjson"), encoding: .utf8)
        precondition(events.contains("gap_started"))
        precondition(events.contains("recovered_after_interruption"), "Gaps and recovery must be explicit, never silently filled")
        precondition(events.contains("partial_chunk_repaired"), "A torn binary tail must be repaired and recorded explicitly")
        let repairedAccSize = (try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        precondition(repairedAccSize == 20, "Recovery must truncate only the incomplete ACC tail")

        let second = try await restarted.begin(metadata: metadata, channels: [channel], startedAt: Date(timeIntervalSince1970: 300))
        try await restarted.appendECG([ResearchECGSample(deviceTimestampNs: 50, voltageMicrovolts: 505)])
        let finished = try await restarted.finish(state: .completed, batteryPercentAtEnd: 88, endedAt: Date(timeIntervalSince1970: 400))
        precondition(finished.captureId == second.captureId && finished.totalBytes >= 12)

        let pendingArchives = try await restarted.pendingArchives()
        precondition(pendingArchives.count == 2, "Interrupted and completed raw stream segments must both remain archiveable")
        guard let completedArchive = pendingArchives.first(where: { $0.captureId == second.captureId }) else {
            preconditionFailure("Completed raw stream capture must remain discoverable")
        }
        precondition(completedArchive.manifest.captureQuality == "completed_with_gaps")
        let completedECG = completedArchive.manifest.channelCoverage?["ecg"]
        precondition(completedECG?.receivedSamples == 1)
        precondition(abs((completedECG?.wallClockSeconds ?? 0) - 100) < 0.001)
        precondition((completedECG?.coveragePct ?? 100) < 1,
                     "Manifest must disclose wall-clock coverage rather than calling sparse data continuous")
        let archiveNames = Set(completedArchive.files.map(\.fileName))
        precondition(archiveNames.contains("manifest.json") && archiveNames.contains("events.ndjson") && archiveNames.contains("ecg-0000.bin"),
                     "Archive plan must include provenance and exact raw chunks")
        try await restarted.deleteVerifiedArchive(completedArchive)
        let afterVerifiedDelete = try await restarted.pendingArchives()
        precondition(afterVerifiedDelete.count == 1 && afterVerifiedDelete[0].captureId == summary.captureId,
                     "Verified cleanup must delete only the selected raw stream capture")

        print("PASS: research raw chunks rotate durably, preserve exact sensor values, expose gaps, recover interruptions, and clean up only after verified archive")
    }


}

#if canImport(Combine) && canImport(Security) && canImport(CryptoKit)
import CryptoKit

private final class ArchiveTransport: URLProtocol {
    enum Mode { case offline, loseResponse, duplicate, processingError, wrongHash }
    static var mode: Mode = .offline
    static var sha = ""
    static let recordingID = UUID().uuidString
    static var archiveWrites = 0
    static var serverHasArchive = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.mode == .offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        if !Self.serverHasArchive { Self.serverHasArchive = true; Self.archiveWrites += 1 }
        if Self.mode == .loseResponse {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let hash = Self.mode == .wrongHash ? String(repeating: "b", count: 64) : Self.sha
        let state = Self.mode == .processingError ? "error" : "insufficient_data"
        let data = Data("{\"ok\":true,\"archived\":true,\"duplicate\":true,\"archive\":{\"verified\":true,\"recording_id\":\"\(Self.recordingID)\",\"sha256\":\"\(hash)\"},\"processing\":{\"state\":\"\(state)\"}}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension RecorderRegression {
    @MainActor static func testUploaderTransport(raw: RawH10RRRecording) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        let file = try await store.save(raw)
        ArchiveTransport.sha = try RecordingStore.sha256(Data(contentsOf: file))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArchiveTransport.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let uploader = AthleteOSUploader(session: session, tokenProvider: { String(repeating: "x", count: 32) })
        ArchiveTransport.mode = .offline
        let offline = await uploader.upload(fileURL: file)
        precondition(offline == nil && !ArchiveTransport.serverHasArchive)
        precondition(FileManager.default.fileExists(atPath: file.path))
        ArchiveTransport.mode = .loseResponse
        let lost = await uploader.upload(fileURL: file)
        precondition(lost == nil && ArchiveTransport.serverHasArchive)
        precondition(FileManager.default.fileExists(atPath: file.path))
        ArchiveTransport.mode = .wrongHash
        let wrong = await uploader.upload(fileURL: file)
        precondition(wrong == nil && FileManager.default.fileExists(atPath: file.path))
        // New uploader models an app restart; exact raw bytes are retried unchanged.
        let restarted = AthleteOSUploader(session: session, tokenProvider: { String(repeating: "x", count: 32) })
        ArchiveTransport.mode = .duplicate
        guard let receipt = await restarted.upload(fileURL: file) else { preconditionFailure("Duplicate retry must receive verified receipt") }
        precondition(receipt.processingState == "insufficient_data" && ArchiveTransport.archiveWrites == 1)
        ArchiveTransport.mode = .processingError
        guard let errorReceipt = await restarted.upload(fileURL: file) else { preconditionFailure("Analysis failure cannot invalidate raw archive") }
        precondition(errorReceipt.processingState == "error")
        _ = try await store.confirmArchive(file, receipt: errorReceipt)
        precondition(!FileManager.default.fileExists(atPath: file.path))
        let jobs = try await store.readySensorCleanups()
        precondition(jobs.count == 1)
        print("PASS: real uploader transport faults, response loss, app restart, duplicate retry, SHA mismatch, archive independent of processing")
    }
}
#endif
