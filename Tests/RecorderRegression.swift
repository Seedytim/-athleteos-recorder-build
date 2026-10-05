import Foundation

@main
struct RecorderRegression {
    static func main() async throws {
        let id = UUID().uuidString
        func receipt(_ status: String) -> Data {
            Data("{\"ok\":true,\"recording\":{\"id\":\"\(id)\"\(status)}}".utf8)
        }
        precondition(UploadReceipt.recordingID(in: receipt("")) == id)
        precondition(UploadReceipt.recordingID(in: receipt(",\"status\":\"complete\"")) == id)
        precondition(UploadReceipt.recordingID(in: receipt(",\"status\":\"error\"")) == nil)
        precondition(UploadReceipt.recordingID(in: receipt(",\"status\":\"processing\"")) == nil)
        precondition(UploadReceipt.recordingID(in: Data("{\"ok\":true}".utf8)) == nil)
        precondition(UploadReceipt.recordingID(in: Data("not json".utf8)) == nil)
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
        print("PASS: complete receipts only, raw samples preserved, saved files discoverable")
    }
}
