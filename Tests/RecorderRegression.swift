import Foundation

@main
struct RecorderRegression {
    static func main() async throws {
        testCompanionControls()
        testConnectionTransitions()
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
        #if canImport(Combine) && canImport(Security) && canImport(CryptoKit)
        try await testUploaderTransport(raw: raw)
        #endif
        print("PASS: verified archive receipts only, SHA must match, raw samples preserved, queue files discoverable and independently deletable")
    }
    static func testCompanionControls() {
        precondition(RecorderCompanionPolicy.isNightAction(URL(string: "athleteos-recorder://night-action")!))
        for url in ["https://night-action", "athleteos-recorder://connect?token=x", "athleteos-recorder://night-action?token=x", "athleteos-recorder://night-action/other", "athleteos-recorder://night-action#start"] {
            precondition(!RecorderCompanionPolicy.isNightAction(URL(string: url)!))
        }
        var gate = NightActionGate()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        precondition(gate.begin(now: now))
        precondition(!gate.begin(now: now.addingTimeInterval(60)), "A second widget tap cannot reverse an in-flight night")
        gate.finish(now: now.addingTimeInterval(61))
        precondition(!gate.begin(now: now.addingTimeInterval(62)), "Duplicate URL delivery immediately after completion must be ignored")
        precondition(gate.begin(now: now.addingTimeInterval(64)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        let start = date(26, 21)
        let morning = RecorderCompanionPolicy.morningReminder(startedAt: start, hour: 7, minute: 15, now: start, calendar: calendar)
        precondition(morning == date(27, 7, 15), "Reminder uses local morning across NZ daylight-saving transition")
        precondition(RecorderCompanionPolicy.morningReminder(startedAt: start, hour: 7, minute: 15, now: date(27, 8), calendar: calendar) == nil, "Restart must not reschedule an old night for tomorrow")
        precondition(RecorderCompanionPolicy.morningReminder(startedAt: start, hour: 24, minute: 0, now: start, calendar: calendar) == nil)
        precondition(RecorderCompanionPolicy.morningReminder(startedAt: date(27, 1), hour: 7, minute: 15, now: date(27, 1), calendar: calendar) == date(27, 7, 15), "Post-midnight start uses this morning")
        print("PASS: strict widget routing, whole-operation duplicate guard, morning reminders across restart and daylight saving")
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
        precondition(NightActionPolicy.afterRecovery(requestedEnd: true, recordingOngoing: false, pendingFetch: false) == .archiveSaved, "Crash-recovered End must never start a new night")
        precondition(NightActionPolicy.afterRecovery(requestedEnd: true, recordingOngoing: false, pendingFetch: true) == .end)
        precondition(NightActionPolicy.afterRecovery(requestedEnd: false, recordingOngoing: false, pendingFetch: false) == .start)
        precondition(NightActionPolicy.afterRecovery(requestedEnd: false, recordingOngoing: true, pendingFetch: false) == .end)
        print("PASS: disconnected connection ownership, both services required, PFTP arbitration, bounded reconnect, Bluetooth loss")
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
