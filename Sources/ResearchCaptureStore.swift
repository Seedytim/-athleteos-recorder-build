import Foundation

enum ResearchCaptureState: String, Codable, Sendable {
    case running
    case stopped
    case interrupted
}

struct ResearchStreamSettings: Codable, Equatable, Sendable {
    let selectedSampleRateHz: Int
    let selectedResolutionBits: Int?
    let selectedRange: Int?
    let supportedSampleRatesHz: [Int]
    let supportedResolutionBits: [Int]
    let supportedRanges: [Int]
}

struct ResearchCaptureConfiguration: Codable, Equatable, Sendable {
    let ecg: ResearchStreamSettings
    let accelerometer: ResearchStreamSettings
    let hrServiceEnabled: Bool
    let sensorTimestampEpoch: String
    let sensorTimestampUnit: String
}

struct ResearchCaptureManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let captureId: UUID
    var state: ResearchCaptureState
    let createdAt: Date
    var updatedAt: Date
    var stoppedAt: Date?
    let deviceId: String
    let deviceModel: String
    let firmwareVersion: String?
    let polarSdkVersion: String
    let appVersion: String
    let appBuild: String
    let safetyExerciseId: String
    let configuration: ResearchCaptureConfiguration
    let storageFormat: String
    let fileProtection: String
    var h10BatteryStartPercent: UInt?
    var h10BatteryEndPercent: UInt?
    var phoneBatteryStartPercent: Int?
    var phoneBatteryEndPercent: Int?
    var interruptionReason: String?
}

struct ResearchECGSample: Equatable, Sendable {
    let sensorTimestampNs: UInt64
    let microvolts: Int32
}

struct ResearchACCSample: Equatable, Sendable {
    let sensorTimestampNs: UInt64
    let xMilliG: Int32
    let yMilliG: Int32
    let zMilliG: Int32
}

struct ResearchHRSample: Codable, Equatable, Sendable {
    let receivedAt: Date
    let heartRateBpm: UInt8
    let rrIntervalsMs: [Int]
    let rrAvailable: Bool
    let contactStatus: Bool
    let contactStatusSupported: Bool
}

struct ResearchCaptureEvent: Codable, Equatable, Sendable {
    let sequence: UInt64
    let at: Date
    let kind: String
    let channel: String?
    let reason: String?
    let sensorTimestampBeforeNs: UInt64?
    let sensorTimestampAfterNs: UInt64?
    let details: [String: String]?
}

struct ResearchCaptureSummary: Identifiable, Equatable, Sendable {
    var id: UUID { captureId }
    let captureId: UUID
    let directory: URL
    let state: ResearchCaptureState
    let createdAt: Date
    let updatedAt: Date
    let ecgSamples: UInt64
    let accSamples: UInt64
    let hrRecords: UInt64
    let totalBytes: UInt64
}

actor ResearchCaptureStore {
    static let shared = ResearchCaptureStore()

    static let schemaVersion = 1
    static let ecgRecordSize = 12
    static let accRecordSize = 20

    private struct ActiveFiles {
        let directory: URL
        var manifest: ResearchCaptureManifest
        let ecg: FileHandle
        let acc: FileHandle
        let hr: FileHandle
        let events: FileHandle
        var eventSequence: UInt64
        var lastEcgTimestamp: UInt64?
        var lastAccTimestamp: UInt64?
        var hrRecords: UInt64
    }

    private let root: URL?
    private var active: ActiveFiles?

    init(root: URL? = nil) {
        self.root = root
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func documents() throws -> URL {
        if let root { return root }
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsDirectoryUnavailable
        }
        return directory
    }

    private func capturesRoot() throws -> URL {
        try documents().appendingPathComponent("ResearchCaptures", isDirectory: true)
    }

    private func directory(for id: UUID) throws -> URL {
        try capturesRoot().appendingPathComponent(id.uuidString + ".aosresearch", isDirectory: true)
    }

    private func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private func fileURL(_ name: String, in directory: URL) -> URL {
        directory.appendingPathComponent(name)
    }

    func start(
        deviceId: String,
        deviceModel: String,
        firmwareVersion: String?,
        polarSdkVersion: String,
        appVersion: String,
        appBuild: String,
        safetyExerciseId: String,
        configuration: ResearchCaptureConfiguration,
        h10BatteryStartPercent: UInt?,
        phoneBatteryStartPercent: Int?
    ) throws -> ResearchCaptureSummary {
        guard active == nil else { throw StoreError.captureAlreadyActive }

        let now = Date()
        let id = UUID()
        let directory = try directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = ResearchCaptureManifest(
            schemaVersion: Self.schemaVersion,
            captureId: id,
            state: .running,
            createdAt: now,
            updatedAt: now,
            stoppedAt: nil,
            deviceId: deviceId,
            deviceModel: deviceModel,
            firmwareVersion: firmwareVersion,
            polarSdkVersion: polarSdkVersion,
            appVersion: appVersion,
            appBuild: appBuild,
            safetyExerciseId: safetyExerciseId,
            configuration: configuration,
            storageFormat: "fixed-width little-endian samples + newline-delimited JSON events",
            fileProtection: "NSFileProtectionCompleteUntilFirstUserAuthentication",
            h10BatteryStartPercent: h10BatteryStartPercent,
            h10BatteryEndPercent: nil,
            phoneBatteryStartPercent: phoneBatteryStartPercent,
            phoneBatteryEndPercent: nil,
            interruptionReason: nil
        )

        try durableWrite(try encoder.encode(manifest), to: manifestURL(in: directory))
        for name in ["ecg.bin", "acc.bin", "hr.ndjson", "events.ndjson"] {
            let url = fileURL(name, in: directory)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            try setBackgroundWritableProtection(url)
        }

        var files = try openFiles(directory: directory, manifest: manifest)
        active = files
        try appendEventInternal(
            to: &files,
            kind: "capture_started",
            channel: nil,
            reason: nil,
            before: nil,
            after: nil,
            details: [
                "safetyExerciseId": safetyExerciseId,
                "storage": manifest.storageFormat
            ]
        )
        active = files
        return try summary(for: directory, manifest: files.manifest, hrRecords: files.hrRecords)
    }

    func resume(captureId: UUID, reason: String) throws -> ResearchCaptureSummary {
        guard active == nil else {
            if active?.manifest.captureId == captureId {
                return try summary(for: active!.directory, manifest: active!.manifest, hrRecords: active!.hrRecords)
            }
            throw StoreError.captureAlreadyActive
        }
        let directory = try directory(for: captureId)
        var manifest = try loadManifest(directory: directory)
        try repairPartialBinaryTail(fileURL("ecg.bin", in: directory), recordSize: Self.ecgRecordSize)
        try repairPartialBinaryTail(fileURL("acc.bin", in: directory), recordSize: Self.accRecordSize)
        try repairPartialJSONLine(fileURL("hr.ndjson", in: directory))
        try repairPartialJSONLine(fileURL("events.ndjson", in: directory))

        manifest.state = .running
        manifest.updatedAt = Date()
        manifest.interruptionReason = nil
        try durableWrite(try encoder.encode(manifest), to: manifestURL(in: directory))

        var files = try openFiles(directory: directory, manifest: manifest)
        try appendEventInternal(
            to: &files,
            kind: "capture_resumed",
            channel: nil,
            reason: reason,
            before: nil,
            after: nil,
            details: nil
        )
        active = files
        return try summary(for: directory, manifest: files.manifest, hrRecords: files.hrRecords)
    }

    func appendECG(_ samples: [ResearchECGSample]) throws {
        guard var files = active else { throw StoreError.noActiveCapture }
        guard !samples.isEmpty else { return }

        if let first = samples.first, let last = files.lastEcgTimestamp {
            try detectTimestampGap(
                files: &files,
                channel: "ecg",
                previous: last,
                next: first.sensorTimestampNs,
                expectedHz: files.manifest.configuration.ecg.selectedSampleRateHz
            )
        }

        var data = Data()
        data.reserveCapacity(samples.count * Self.ecgRecordSize)
        for sample in samples {
            data.appendLittleEndian(sample.sensorTimestampNs)
            data.appendLittleEndian(sample.microvolts)
        }
        try appendDurably(data, to: files.ecg)
        files.lastEcgTimestamp = samples.last?.sensorTimestampNs
        active = files
    }

    func appendACC(_ samples: [ResearchACCSample]) throws {
        guard var files = active else { throw StoreError.noActiveCapture }
        guard !samples.isEmpty else { return }

        if let first = samples.first, let last = files.lastAccTimestamp {
            try detectTimestampGap(
                files: &files,
                channel: "acc",
                previous: last,
                next: first.sensorTimestampNs,
                expectedHz: files.manifest.configuration.accelerometer.selectedSampleRateHz
            )
        }

        var data = Data()
        data.reserveCapacity(samples.count * Self.accRecordSize)
        for sample in samples {
            data.appendLittleEndian(sample.sensorTimestampNs)
            data.appendLittleEndian(sample.xMilliG)
            data.appendLittleEndian(sample.yMilliG)
            data.appendLittleEndian(sample.zMilliG)
        }
        try appendDurably(data, to: files.acc)
        files.lastAccTimestamp = samples.last?.sensorTimestampNs
        active = files
    }

    func appendHR(_ samples: [ResearchHRSample]) throws {
        guard var files = active else { throw StoreError.noActiveCapture }
        guard !samples.isEmpty else { return }
        var data = Data()
        for sample in samples {
            data.append(try lineEncoder.encode(sample))
            data.append(0x0A)
        }
        try appendDurably(data, to: files.hr)
        files.hrRecords += UInt64(samples.count)
        active = files
    }

    func recordEvent(
        kind: String,
        channel: String? = nil,
        reason: String? = nil,
        sensorTimestampBeforeNs: UInt64? = nil,
        sensorTimestampAfterNs: UInt64? = nil,
        details: [String: String]? = nil
    ) throws {
        guard var files = active else { throw StoreError.noActiveCapture }
        try appendEventInternal(
            to: &files,
            kind: kind,
            channel: channel,
            reason: reason,
            before: sensorTimestampBeforeNs,
            after: sensorTimestampAfterNs,
            details: details
        )
        active = files
    }

    func finish(h10BatteryEndPercent: UInt?, phoneBatteryEndPercent: Int?) throws -> ResearchCaptureSummary {
        guard var files = active else { throw StoreError.noActiveCapture }
        try appendEventInternal(
            to: &files,
            kind: "capture_stopped",
            channel: nil,
            reason: nil,
            before: nil,
            after: nil,
            details: nil
        )
        let now = Date()
        files.manifest.state = .stopped
        files.manifest.stoppedAt = now
        files.manifest.updatedAt = now
        files.manifest.h10BatteryEndPercent = h10BatteryEndPercent
        files.manifest.phoneBatteryEndPercent = phoneBatteryEndPercent
        try durableWrite(try encoder.encode(files.manifest), to: manifestURL(in: files.directory))
        try syncAndClose(files)
        let result = try summary(for: files.directory, manifest: files.manifest, hrRecords: files.hrRecords)
        active = nil
        return result
    }

    func interrupt(reason: String) throws -> ResearchCaptureSummary {
        guard var files = active else { throw StoreError.noActiveCapture }
        try appendEventInternal(
            to: &files,
            kind: "capture_interrupted",
            channel: nil,
            reason: reason,
            before: nil,
            after: nil,
            details: nil
        )
        files.manifest.state = .interrupted
        files.manifest.updatedAt = Date()
        files.manifest.interruptionReason = reason
        try durableWrite(try encoder.encode(files.manifest), to: manifestURL(in: files.directory))
        try syncAndClose(files)
        let result = try summary(for: files.directory, manifest: files.manifest, hrRecords: files.hrRecords)
        active = nil
        return result
    }

    func snapshot() throws -> ResearchCaptureSummary? {
        guard let active else { return nil }
        return try summary(for: active.directory, manifest: active.manifest, hrRecords: active.hrRecords)
    }

    func summary(captureId: UUID) throws -> ResearchCaptureSummary {
        let directory = try directory(for: captureId)
        let manifest = try loadManifest(directory: directory)
        return try summary(for: directory, manifest: manifest, hrRecords: countCompleteJSONLines(fileURL("hr.ndjson", in: directory)))
    }

    func list() throws -> [ResearchCaptureSummary] {
        let root = try capturesRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "aosresearch" }

        return try directories.compactMap { directory in
            guard FileManager.default.fileExists(atPath: manifestURL(in: directory).path) else { return nil }
            let manifest = try loadManifest(directory: directory)
            return try summary(
                for: directory,
                manifest: manifest,
                hrRecords: countCompleteJSONLines(fileURL("hr.ndjson", in: directory))
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func loadManifest(captureId: UUID) throws -> ResearchCaptureManifest {
        try loadManifest(directory: directory(for: captureId))
    }

    func repair(captureId: UUID) throws {
        let directory = try directory(for: captureId)
        try repairPartialBinaryTail(fileURL("ecg.bin", in: directory), recordSize: Self.ecgRecordSize)
        try repairPartialBinaryTail(fileURL("acc.bin", in: directory), recordSize: Self.accRecordSize)
        try repairPartialJSONLine(fileURL("hr.ndjson", in: directory))
        try repairPartialJSONLine(fileURL("events.ndjson", in: directory))
    }

    private func openFiles(directory: URL, manifest: ResearchCaptureManifest) throws -> ActiveFiles {
        let ecg = try writableHandle(fileURL("ecg.bin", in: directory))
        let acc = try writableHandle(fileURL("acc.bin", in: directory))
        let hr = try writableHandle(fileURL("hr.ndjson", in: directory))
        let events = try writableHandle(fileURL("events.ndjson", in: directory))
        let sequence = countCompleteJSONLines(fileURL("events.ndjson", in: directory))
        let hrRecords = countCompleteJSONLines(fileURL("hr.ndjson", in: directory))
        return ActiveFiles(
            directory: directory,
            manifest: manifest,
            ecg: ecg,
            acc: acc,
            hr: hr,
            events: events,
            eventSequence: sequence,
            lastEcgTimestamp: try lastUInt64Timestamp(fileURL("ecg.bin", in: directory), recordSize: Self.ecgRecordSize),
            lastAccTimestamp: try lastUInt64Timestamp(fileURL("acc.bin", in: directory), recordSize: Self.accRecordSize),
            hrRecords: hrRecords
        )
    }

    private func writableHandle(_ url: URL) throws -> FileHandle {
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return try writableHandle(url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func detectTimestampGap(
        files: inout ActiveFiles,
        channel: String,
        previous: UInt64,
        next: UInt64,
        expectedHz: Int
    ) throws {
        guard expectedHz > 0, next > previous else { return }
        let expectedNs = UInt64(1_000_000_000 / expectedHz)
        let threshold = max(expectedNs * 4, 250_000_000)
        if next - previous > threshold {
            try appendEventInternal(
                to: &files,
                kind: "timestamp_gap",
                channel: channel,
                reason: "sensor timestamp discontinuity",
                before: previous,
                after: next,
                details: [
                    "gapNs": String(next - previous),
                    "expectedIntervalNs": String(expectedNs)
                ]
            )
        }
    }

    private func appendEventInternal(
        to files: inout ActiveFiles,
        kind: String,
        channel: String?,
        reason: String?,
        before: UInt64?,
        after: UInt64?,
        details: [String: String]?
    ) throws {
        let event = ResearchCaptureEvent(
            sequence: files.eventSequence,
            at: Date(),
            kind: kind,
            channel: channel,
            reason: reason,
            sensorTimestampBeforeNs: before,
            sensorTimestampAfterNs: after,
            details: details
        )
        var data = try lineEncoder.encode(event)
        data.append(0x0A)
        try appendDurably(data, to: files.events)
        files.eventSequence += 1
    }

    private func loadManifest(directory: URL) throws -> ResearchCaptureManifest {
        try decoder.decode(ResearchCaptureManifest.self, from: Data(contentsOf: manifestURL(in: directory)))
    }

    private func summary(for directory: URL, manifest: ResearchCaptureManifest, hrRecords: UInt64) throws -> ResearchCaptureSummary {
        let ecgSize = try fileSize(fileURL("ecg.bin", in: directory))
        let accSize = try fileSize(fileURL("acc.bin", in: directory))
        let hrSize = try fileSize(fileURL("hr.ndjson", in: directory))
        let eventSize = try fileSize(fileURL("events.ndjson", in: directory))
        let manifestSize = try fileSize(manifestURL(in: directory))
        return ResearchCaptureSummary(
            captureId: manifest.captureId,
            directory: directory,
            state: manifest.state,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt,
            ecgSamples: ecgSize / UInt64(Self.ecgRecordSize),
            accSamples: accSize / UInt64(Self.accRecordSize),
            hrRecords: hrRecords,
            totalBytes: ecgSize + accSize + hrSize + eventSize + manifestSize
        )
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let value = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return UInt64(value)
    }

    private func countCompleteJSONLines(_ url: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return UInt64(data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } })
    }

    private func lastUInt64Timestamp(_ url: URL, recordSize: Int) throws -> UInt64? {
        let size = Int(try fileSize(url))
        guard size >= recordSize else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(size - recordSize))
        guard let data = try handle.read(upToCount: 8), data.count == 8 else { return nil }
        return data.withUnsafeBytes { raw in
            UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self))
        }
    }

    private func repairPartialBinaryTail(_ url: URL, recordSize: Int) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let size = Int(try fileSize(url))
        let aligned = size - (size % recordSize)
        guard aligned != size else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(aligned))
        try handle.synchronize()
    }

    private func repairPartialJSONLine(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.last != 0x0A else { return }
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.synchronize()
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(lastNewline + 1))
        try handle.synchronize()
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try setBackgroundWritableProtection(url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func appendDurably(_ data: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func syncAndClose(_ files: ActiveFiles) throws {
        for handle in [files.ecg, files.acc, files.hr, files.events] {
            try handle.synchronize()
            try handle.close()
        }
    }

    private func setBackgroundWritableProtection(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    enum StoreError: Error {
        case documentsDirectoryUnavailable
        case captureAlreadyActive
        case noActiveCapture
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { raw in
            append(contentsOf: raw)
        }
    }
}
