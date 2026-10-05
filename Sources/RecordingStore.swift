import Foundation

struct SavedRecordingFile: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let date: Date
}

actor RecordingStore {
    func list() throws -> [SavedRecordingFile] {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsDirectoryUnavailable
        }
        let directory = documents.appendingPathComponent("OvernightRecordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .map { url in
                let values = try url.resourceValues(forKeys: [.creationDateKey])
                return SavedRecordingFile(url: url, date: values.creationDate ?? .distantPast)
            }.sorted { $0.date > $1.date }
    }

    enum StoreError: Error {
        case documentsDirectoryUnavailable
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func save(_ recording: RawH10RRRecording) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsDirectoryUnavailable
        }

        let directory = documents.appendingPathComponent("OvernightRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appendingPathComponent("\(recording.id.uuidString).json")
        let data = try encoder.encode(recording)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }
}
