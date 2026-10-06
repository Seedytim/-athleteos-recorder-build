import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

struct SensorRecordingIdentity: Codable, Equatable, Sendable {
    let deviceId: String
    let exerciseId: String
}

struct ArchivedSensorCleanup: Codable, Sendable {
    let fileName: String
    let identity: SensorRecordingIdentity
    let receipt: VerifiedArchiveReceipt
    var sensorStored: Bool? = nil
}

struct SavedRecordingFile: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let date: Date
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

actor RecordingStore {
    static let shared = RecordingStore()
    private let root: URL?
    private let digest: @Sendable (Data) throws -> String
    private let removeFile: @Sendable (URL) throws -> Void
    // Tests inject an isolated directory and digest; production always uses CryptoKit.
    init(root: URL? = nil, digest: @escaping @Sendable (Data) throws -> String = { try RecordingStore.sha256($0) },
         removeFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.root = root
        self.digest = digest
        self.removeFile = removeFile
    }
    nonisolated static func sha256(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        throw StoreError.hashUnavailable
        #endif
    }
    private func documents() throws -> URL {
        guard let directory = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsDirectoryUnavailable
        }
        return directory
    }
    private func rawDirectory() throws -> URL { try documents().appendingPathComponent("OvernightRecordings", isDirectory: true) }
    private func journalDirectory() throws -> URL { try documents().appendingPathComponent("ArchiveReceipts", isDirectory: true) }

    func list() throws -> [SavedRecordingFile] {
        let documents = try documents()
        let directory = documents.appendingPathComponent("OvernightRecordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .map { url in
                let values = try url.resourceValues(forKeys: [.creationDateKey])
                return SavedRecordingFile(url: url, date: values.creationDate ?? .distantPast)
            }.sorted { $0.date > $1.date }
    }

    func delete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try removeFile(url)
    }

    func exerciseId(for url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let recording = try JSONDecoder.iso8601.decode(RawH10RRRecording.self, from: data)
        let value = recording.exerciseId.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func sensorIdentity(for url: URL) throws -> SensorRecordingIdentity {
        let raw = try JSONDecoder.iso8601.decode(RawH10RRRecording.self, from: Data(contentsOf: url))
        guard !raw.deviceId.isEmpty, !raw.exerciseId.isEmpty else { throw StoreError.invalidIdentity }
        return SensorRecordingIdentity(deviceId: raw.deviceId, exerciseId: raw.exerciseId)
    }

    /// Journal the verified receipt BEFORE local deletion. A crash at either side
    /// leaves enough durable evidence to safely finish local and sensor cleanup.
    func confirmArchive(_ url: URL, receipt: VerifiedArchiveReceipt) throws -> SensorRecordingIdentity {
        let data = try Data(contentsOf: url)
        guard try digest(data) == receipt.sha256 else { throw StoreError.archiveMismatch }
        let identity = try sensorIdentity(for: url)
        let raw = try JSONDecoder.iso8601.decode(RawH10RRRecording.self, from: data)
        let job = ArchivedSensorCleanup(fileName: url.lastPathComponent, identity: identity, receipt: receipt,
            sensorStored: raw.storageMode != "phone_live")
        let directory = try journalDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent(job.fileName)
        try durableWrite(try encoder.encode(job), to: journal)
        try delete(url)
        return identity
    }

    func readySensorCleanups() throws -> [ArchivedSensorCleanup] {
        let directory = try journalDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var ready: [ArchivedSensorCleanup] = []
        for url in urls where url.pathExtension == "json" {
            let job = try JSONDecoder().decode(ArchivedSensorCleanup.self, from: Data(contentsOf: url))
            guard job.fileName == url.lastPathComponent else { throw StoreError.invalidIdentity }
            let raw = try rawDirectory().appendingPathComponent(job.fileName)
            if FileManager.default.fileExists(atPath: raw.path) {
                // Local deletion previously failed or the app exited after journaling.
                guard try digest(Data(contentsOf: raw)) == job.receipt.sha256 else { throw StoreError.archiveMismatch }
                try delete(raw)
            }
            if job.sensorStored == false {
                // Phone-only episodes must never issue an H10 delete request.
                try delete(url)
            } else {
                ready.append(job)
            }
        }
        return ready
    }

    func finishSensorCleanup(_ job: ArchivedSensorCleanup) throws {
        let journal = try journalDirectory().appendingPathComponent(job.fileName)
        try delete(journal)
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    enum StoreError: Error {
        case documentsDirectoryUnavailable
        case hashUnavailable
        case archiveMismatch
        case invalidIdentity
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func save(_ recording: RawH10RRRecording) throws -> URL {
        let documents = try documents()

        let directory = documents.appendingPathComponent("OvernightRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appendingPathComponent("\(recording.id.uuidString).json")
        let data = try encoder.encode(recording)
        try durableWrite(data, to: file)
        return file
    }
}
