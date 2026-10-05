import Foundation

@main
struct RecorderRegression {
    static func main() async throws {
        let id = UUID().uuidString
        let sha = String(repeating: "a", count: 64)
        func receipt(archived: Bool = true, verified: Bool = true, hash: String? = nil, processing: String = "complete") -> Data {
            Data("{\"ok\":true,\"archived\":\(archived),\"archive\":{\"verified\":\(verified),\"recording_id\":\"\(id)\",\"sha256\":\"\(hash ?? sha)\"},\"processing\":{\"state\":\"\(processing)\"}}".utf8)
        }
        precondition(UploadReceipt.verifiedArchive(in: receipt(), expectedSHA256: sha)?.recordingID == id)
        precondition(UploadReceipt.verifiedArchive(in: receipt(processing: "insufficient_data"), expectedSHA256: sha)?.recordingID == id)
        precondition(UploadReceipt.verifiedArchive(in: receipt(archived: false), expectedSHA256: sha) == nil)
        precondition(UploadReceipt.verifiedArchive(in: receipt(verified: false), expectedSHA256: sha) == nil)
        precondition(UploadReceipt.verifiedArchive(in: receipt(hash: String(repeating: "b", count: 64)), expectedSHA256: sha) == nil)
        precondition(UploadReceipt.verifiedArchive(in: Data("{\"ok\":true}".utf8), expectedSHA256: sha) == nil)
        precondition(UploadReceipt.verifiedArchive(in: Data("not json".utf8), expectedSHA256: sha) == nil)
        let samples: [UInt32] = [800, 810, 0, 2001, 795]
        let raw = RawH10RRRecording(deviceId: "TEST", exerciseId: "fixture", startedAt: Date(), stoppedAt: Date(), fetchedAt: Date(), polarSdkVersion: "test", firmwareVersion: "test", batteryPercentAtFetch: 80, recordingIntervalSeconds: 1, rrSamplesRaw: samples)
        let store = RecordingStore()
        let url = try await store.save(raw)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(RawH10RRRecording.self, from: Data(contentsOf: url))
        precondition(saved.rrSamplesRaw == samples, "Raw RR must remain unchanged, including outliers")
        let files = try await store.list()
        precondition(files.contains { $0.url == url }, "Saved files must remain discoverable")
        let savedExerciseId = try await store.exerciseId(for: url)
        precondition(savedExerciseId == "fixture", "Saved file must retain its sensor exercise identity")
        try await store.delete(url)
        precondition(!FileManager.default.fileExists(atPath: url.path), "Verified local cleanup must remove only the selected file")
        print("PASS: verified archive receipts only, SHA must match, raw samples preserved, queue files discoverable and independently deletable")
    }
}
