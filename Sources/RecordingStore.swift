import Foundation

actor RecordingStore {
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
