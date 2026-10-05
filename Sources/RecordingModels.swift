import Foundation

struct RawH10RRRecording: Codable {
    let schemaVersion: Int
    let id: UUID
    let deviceId: String
    let exerciseId: String
    let startedAt: Date?
    let stoppedAt: Date
    let fetchedAt: Date
    let polarSdkVersion: String
    let firmwareVersion: String?
    let batteryPercentAtFetch: UInt?
    let recordingIntervalSeconds: UInt32
    let sampleType: String
    let sampleEncoding: String
    let rrSamplesRaw: [UInt32]

    init(
        deviceId: String,
        exerciseId: String,
        startedAt: Date?,
        stoppedAt: Date,
        fetchedAt: Date,
        polarSdkVersion: String,
        firmwareVersion: String?,
        batteryPercentAtFetch: UInt?,
        recordingIntervalSeconds: UInt32,
        rrSamplesRaw: [UInt32]
    ) {
        self.schemaVersion = 1
        self.id = UUID()
        self.deviceId = deviceId
        self.exerciseId = exerciseId
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.fetchedAt = fetchedAt
        self.polarSdkVersion = polarSdkVersion
        self.firmwareVersion = firmwareVersion
        self.batteryPercentAtFetch = batteryPercentAtFetch
        self.recordingIntervalSeconds = recordingIntervalSeconds
        self.sampleType = "rr"
        self.sampleEncoding = "polar_h10_exercise_rr_ms_uint32"
        self.rrSamplesRaw = rrSamplesRaw
    }
}
