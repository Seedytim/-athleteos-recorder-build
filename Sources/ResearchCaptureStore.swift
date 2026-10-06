import Foundation

struct ResearchECGSample: Sendable, Equatable {
    let deviceTimestampNs: UInt64
    let voltageMicrovolts: Int32
}

struct ResearchACCSample: Sendable, Equatable {
    let deviceTimestampNs: UInt64
    let xMilliG: Int32
    let yMilliG: Int32
    let zMilliG: Int32
}

struct ResearchHRSample: Codable, Sendable, Equatable {
    let receivedAt: Date
    let bpm: UInt8
    let rrMs: [Int]
    let rrAvailable: Bool
    let contactStatus: Bool
    let contactStatusSupported: Bool
    var receivedAtUnixMs: Double? = nil
    var streamSegmentId: UUID? = nil
}

struct ResearchChannelDescriptor: Codable, Sendable, Equatable {
    let channel: String
    let source: String
    let sampleRateHz: UInt32?
    let unit: String
    let recordEncoding: String
    let supportedSettings: [String: [UInt32]]
    let selectedSettings: [String: UInt32]
}

struct ResearchDeviceMetadata: Codable, Sendable, Equatable {
    let deviceId: String
    let model: String
    let firmwareVersion: String?
    let polarSdkVersion: String
    let appVersion: String
    let appBuild: String
    let internalRRExerciseId: String
    let batteryPercentAtStart: UInt?
}

struct ResearchCaptureFile: Codable, Sendable, Equatable {
    let channel: String
    let fileName: String
    let recordEncoding: String
    var byteCount: UInt64
    var recordCount: UInt64
}

struct ResearchChannelCoverage: Codable, Sendable, Equatable {
    let expectedSampleRateHz: UInt32
    let receivedSamples: UInt64
    let recordedSeconds: Double
    let wallClockSeconds: Double
    let coveragePct: Double
}

struct ResearchCaptureManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var captureId: UUID
    var state: String
    var startedAt: Date
    var endedAt: Date?
    var device: ResearchDeviceMetadata
    var batteryPercentAtEnd: UInt?
    var deviceTimestampEpoch: String
    var hostTimestampEncoding: String
    var internalRRRole: String
    var rawValuePolicy: String
    var channels: [ResearchChannelDescriptor]
    var files: [ResearchCaptureFile]
    /// Final wall-clock coverage. Optional so build-19 can still decode archives
    /// created by older Recorder builds without mutating their raw files.
    var channelCoverage: [String: ResearchChannelCoverage]? = nil
    var captureQuality: String? = nil
    /// RR episode origin; startedAt remains the actual start of this raw segment.
    var episodeStartedAt: Date? = nil
    var recordingMode: String? = nil
}

struct ResearchCaptureEvent: Codable, Sendable, Equatable {
    let at: Date
    let kind: String
    let detail: String
}

struct ResearchTimeAnchor: Codable, Sendable, Equatable {
    let channel: String
    let deviceTimestampNs: UInt64
    let hostReceivedAt: Date
    // UInt64 JSON numbers exceed JavaScript's exact integer range.
    var deviceTimestampNsExact: String? = nil
    var firstDeviceTimestampNsExact: String? = nil
    var hostReceivedAtUnixMs: Double? = nil
    var hostUptimeSeconds: Double? = nil
    var streamSegmentId: UUID? = nil
    var referenceSample: String? = nil
    var packetSampleCount: Int? = nil
}

struct ResearchCaptureSummary: Sendable, Equatable {
    let captureId: UUID
    let directory: URL
    let totalBytes: UInt64
    let fileCount: Int
}

struct ResearchArchiveFile: Sendable, Equatable {
    let fileName: String
    let url: URL
    let channel: String?
    let recordEncoding: String?
    let byteCount: UInt64
}

struct ResearchCaptureArchive: Sendable, Equatable {
    let captureId: UUID
    let directory: URL
    let manifest: ResearchCaptureManifest
    let files: [ResearchArchiveFile]
}

actor ResearchCaptureStore {
    static let shared = ResearchCaptureStore()

    enum StoreError: Error {
        case documentsDirectoryUnavailable
        case captureAlreadyActive
        case noActiveCapture
        case invalidManifest
        case staleCapture
    }

    enum FinalState: String {
        case completed
        case interrupted
        case abandoned
    }

    private struct ChannelWriter {
        var channel: String
        var recordEncoding: String
        var chunkIndex: Int
        var fileURL: URL
        var handle: FileHandle
        var bytes: UInt64
        var records: UInt64
        var bytesSinceSync: UInt64
        var lastSyncAt: Date
    }

    private struct ActiveCapture {
        var directory: URL
        var manifestURL: URL
        var eventsURL: URL
        var manifest: ResearchCaptureManifest
        var writers: [String: ChannelWriter]
    }

    private let root: URL?
    private let chunkLimitBytes: UInt64
    private var active: ActiveCapture?

    init(root: URL? = nil, chunkLimitBytes: UInt64 = 6 * 1024 * 1024) {
        self.root = root
        self.chunkLimitBytes = chunkLimitBytes
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func documents() throws -> URL {
        if let root { return root }
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsDirectoryUnavailable
        }
        return directory
    }

    private func capturesDirectory() throws -> URL {
        try documents().appendingPathComponent("ResearchCaptures", isDirectory: true)
    }

    func begin(
        metadata: ResearchDeviceMetadata,
        channels: [ResearchChannelDescriptor],
        startedAt: Date = Date()
    ) throws -> ResearchCaptureSummary {
        guard active == nil else { throw StoreError.captureAlreadyActive }

        let captureId = UUID()
        let directory = try capturesDirectory().appendingPathComponent(captureId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifestURL = directory.appendingPathComponent("manifest.json")
        let eventsURL = directory.appendingPathComponent("events.ndjson")
        createProtectedFile(at: eventsURL)

        let manifest = ResearchCaptureManifest(
            schemaVersion: 1,
            captureId: captureId,
            state: "recording",
            startedAt: startedAt,
            endedAt: nil,
            device: metadata,
            batteryPercentAtEnd: nil,
            deviceTimestampEpoch: "2000-01-01T00:00:00Z",
            hostTimestampEncoding: "ISO-8601 UTC",
            internalRRRole: metadata.internalRRExerciseId.hasPrefix("LIVE_")
                ? "phone-owned live RR; no H10 internal recording; Bluetooth gaps are unrecoverable"
                : "independent safety/master record; never deleted because research streaming fails",
            rawValuePolicy: "raw sensor values are preserved unchanged; any future cleaning must be stored separately with provenance",
            channels: channels,
            files: []
        )

        var capture = ActiveCapture(
            directory: directory,
            manifestURL: manifestURL,
            eventsURL: eventsURL,
            manifest: manifest,
            writers: [:]
        )
        try writeManifest(capture.manifest, to: manifestURL)
        active = capture
        active?.manifest.recordingMode = metadata.internalRRExerciseId.hasPrefix("LIVE_") ? "phone_live" : "sensor_stored"
        if let active { try writeManifest(active.manifest, to: manifestURL) }
        try appendEvent(kind: "capture_started", detail: "Raw capture started; recording mode is explicit in the manifest.", at: startedAt)
        capture = active ?? capture
        return ResearchCaptureSummary(captureId: captureId, directory: directory, totalBytes: 0, fileCount: capture.manifest.files.count)
    }

    func recoverInterruptedCaptures(now: Date = Date()) throws -> Int {
        let directory = try capturesDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recovered = 0

        for captureDir in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            // Repeated foreground recovery must never finalize a live writer.
            if active?.directory.resolvingSymlinksInPath().standardizedFileURL == captureDir.resolvingSymlinksInPath().standardizedFileURL { continue }
            let values = try captureDir.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let manifestURL = captureDir.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            var manifest = try decoder.decode(ResearchCaptureManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.state == "recording" else { continue }

            var repairDetails: [String] = []
            for index in manifest.files.indices {
                let file = manifest.files[index]
                let rawURL = captureDir.appendingPathComponent(file.fileName)
                guard FileManager.default.fileExists(atPath: rawURL.path),
                      let recordSize = fixedRecordSize(for: file.recordEncoding) else { continue }

                let actualSize = UInt64((try? rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let validSize = actualSize - (actualSize % UInt64(recordSize))
                if validSize != actualSize {
                    let handle = try FileHandle(forWritingTo: rawURL)
                    try handle.truncate(atOffset: validSize)
                    try handle.synchronize()
                    try handle.close()
                    repairDetails.append("\(file.fileName): trimmed \(actualSize - validSize) incomplete byte(s)")
                }
                manifest.files[index].byteCount = validSize
                manifest.files[index].recordCount = validSize / UInt64(recordSize)
            }

            // A crash can leave a partial NDJSON line and stale manifest counts.
            // Keep only complete records, then recount from durable bytes.
            for index in manifest.files.indices where manifest.files[index].recordEncoding.hasPrefix("ndjson:") {
                let rawURL = captureDir.appendingPathComponent(manifest.files[index].fileName)
                guard FileManager.default.fileExists(atPath: rawURL.path) else { continue }
                let bytes = try Data(contentsOf: rawURL)
                let validEnd = bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
                if validEnd < bytes.count {
                    let handle = try FileHandle(forWritingTo: rawURL)
                    try handle.truncate(atOffset: UInt64(validEnd))
                    try handle.synchronize()
                    try handle.close()
                    repairDetails.append("\(manifest.files[index].fileName): trimmed incomplete NDJSON tail")
                }
                manifest.files[index].byteCount = UInt64(validEnd)
                manifest.files[index].recordCount = UInt64(bytes.prefix(validEnd).filter { $0 == 0x0A }.count)
            }

            let event = ResearchCaptureEvent(
                at: now,
                kind: "recovered_after_interruption",
                detail: "Recorder relaunched while this capture was still marked recording. Existing raw chunks were retained; no inferred samples were inserted."
            )
            try appendLine(try lineEncoder.encode(event), to: captureDir.appendingPathComponent("events.ndjson"))
            if !repairDetails.isEmpty {
                let repair = ResearchCaptureEvent(
                    at: now,
                    kind: "partial_chunk_repaired",
                    detail: repairDetails.joined(separator: "; ")
                )
                try appendLine(try lineEncoder.encode(repair), to: captureDir.appendingPathComponent("events.ndjson"))
            }
            manifest.state = FinalState.interrupted.rawValue
            manifest.endedAt = now
            finalizeCoverage(manifest: &manifest, endedAt: now)
            try writeManifest(manifest, to: manifestURL)
            recovered += 1
        }
        return recovered
    }

    func ensureEpisodeCapture(metadata: ResearchDeviceMetadata, channels: [ResearchChannelDescriptor],
                              episodeStartedAt: Date, now: Date = Date()) throws -> UUID {
        if let capture = active {
            if capture.manifest.device.deviceId == metadata.deviceId &&
                capture.manifest.device.internalRRExerciseId == metadata.internalRRExerciseId {
                active?.manifest.channels = channels
                if let active { try writeManifest(active.manifest, to: active.manifestURL) }
                // Packet confirmation, not starting subscriptions, closes a gap.
                try appendEvent(kind: "stream_setup", detail: "Matching episode subscriptions prepared; awaiting fresh packets.", at: now)
                return capture.manifest.captureId
            }
            try appendEvent(kind: "episode_identity_changed", detail: "Retaining previous segment; a different RR episode is starting.", at: now)
            _ = try finish(state: .interrupted, batteryPercentAtEnd: nil, endedAt: now)
        }
        let summary = try begin(metadata: metadata, channels: channels, startedAt: now)
        active?.manifest.episodeStartedAt = episodeStartedAt
        if let capture = active { try writeManifest(capture.manifest, to: capture.manifestURL) }
        return summary.captureId
    }

    private func validateCapture(_ captureId: UUID?) throws {
        if let captureId, active?.manifest.captureId != captureId { throw StoreError.staleCapture }
    }

    func appendECG(_ samples: [ResearchECGSample], captureId: UUID? = nil) throws {
        try Task.checkCancellation()
        try validateCapture(captureId)
        guard !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 12)
        for sample in samples {
            appendLittleEndian(sample.deviceTimestampNs, to: &data)
            appendLittleEndian(sample.voltageMicrovolts, to: &data)
        }
        try appendBinary(channel: "ecg", recordEncoding: "little_endian:uint64_timestamp_ns,int32_microvolts", data: data, recordCount: UInt64(samples.count))
    }

    func appendACC(_ samples: [ResearchACCSample], captureId: UUID? = nil) throws {
        try Task.checkCancellation()
        try validateCapture(captureId)
        guard !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 20)
        for sample in samples {
            appendLittleEndian(sample.deviceTimestampNs, to: &data)
            appendLittleEndian(sample.xMilliG, to: &data)
            appendLittleEndian(sample.yMilliG, to: &data)
            appendLittleEndian(sample.zMilliG, to: &data)
        }
        try appendBinary(channel: "acc", recordEncoding: "little_endian:uint64_timestamp_ns,int32_x_mg,int32_y_mg,int32_z_mg", data: data, recordCount: UInt64(samples.count))
    }

    func appendHR(_ samples: [ResearchHRSample], captureId: UUID? = nil) throws {
        try Task.checkCancellation()
        try validateCapture(captureId)
        guard !samples.isEmpty else { return }
        for sample in samples {
            if active?.manifest.recordingMode == "phone_live" {
                var line = try lineEncoder.encode(sample)
                line.append(0x0A)
                try appendBinary(channel: "hr", recordEncoding: "ndjson:ResearchHRSample", data: line, recordCount: 1)
            } else {
                try appendLine(try lineEncoder.encode(sample), toActiveNamedFile: "hr.ndjson", channel: "hr", recordEncoding: "ndjson:ResearchHRSample")
            }
        }
    }

    func appendEvent(kind: String, detail: String, at: Date = Date()) throws {
        guard let active else { throw StoreError.noActiveCapture }
        let event = ResearchCaptureEvent(at: at, kind: kind, detail: detail)
        try appendLine(try lineEncoder.encode(event), to: active.eventsURL)
    }

    func appendTimeAnchor(channel: String, deviceTimestampNs: UInt64, hostReceivedAt: Date = Date(), captureId: UUID? = nil, firstDeviceTimestampNs: UInt64? = nil, hostUptimeSeconds: Double? = nil, streamSegmentId: UUID? = nil, packetSampleCount: Int? = nil) throws {
        try Task.checkCancellation()
        try validateCapture(captureId)
        let anchor = ResearchTimeAnchor(
            channel: channel,
            deviceTimestampNs: deviceTimestampNs,
            hostReceivedAt: hostReceivedAt,
            deviceTimestampNsExact: String(deviceTimestampNs),
            firstDeviceTimestampNsExact: firstDeviceTimestampNs.map(String.init),
            hostReceivedAtUnixMs: hostReceivedAt.timeIntervalSince1970 * 1000,
            hostUptimeSeconds: hostUptimeSeconds,
            streamSegmentId: streamSegmentId,
            referenceSample: firstDeviceTimestampNs == nil ? "legacy_unspecified" : "last_sample_in_packet_receipt_estimate",
            packetSampleCount: packetSampleCount
        )
        var line = try lineEncoder.encode(anchor)
        line.append(0x0A)
        // Per-packet anchors must not fsync/rewrite the manifest every packet.
        // Use the same bounded, rotating durable writer as raw samples.
        try appendBinary(channel: "timebase", recordEncoding: "ndjson:ResearchTimeAnchor", data: line, recordCount: 1)
    }

    func finish(
        state: FinalState = .completed,
        batteryPercentAtEnd: UInt?,
        endedAt: Date = Date()
    ) throws -> ResearchCaptureSummary {
        guard var capture = active else { throw StoreError.noActiveCapture }

        for (_, writer) in capture.writers {
            try writer.handle.synchronize()
        }
        for (_, writer) in capture.writers { try? writer.handle.close() }
        capture.writers.removeAll()
        active?.writers.removeAll()

        capture.manifest.state = state.rawValue
        capture.manifest.endedAt = endedAt
        capture.manifest.batteryPercentAtEnd = batteryPercentAtEnd
        finalizeCoverage(manifest: &capture.manifest, endedAt: endedAt)
        try writeManifest(capture.manifest, to: capture.manifestURL)

        let total = capture.manifest.files.reduce(UInt64(0)) { $0 + $1.byteCount }
        let summary = ResearchCaptureSummary(
            captureId: capture.manifest.captureId,
            directory: capture.directory,
            totalBytes: total,
            fileCount: capture.manifest.files.count
        )
        active = nil
        return summary
    }

    func activeCaptureId() -> UUID? {
        active?.manifest.captureId
    }

    /// Export received RR notifications, not an H10 memory file. Stable episode
    /// identity makes retries byte-identical. Every interrupted segment is kept.
    func phoneEpisodeRecording(id: UUID, episodeId: String, startedAt: Date, endedAt: Date) throws -> RawH10RRRecording {
        let segments = try pendingArchives().filter { $0.manifest.device.internalRRExerciseId == episodeId }
        guard let first = segments.first else { throw StoreError.invalidManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var packets: [ResearchHRSample] = []
        for segment in segments {
            for file in segment.files where file.channel == "hr" {
                let bytes = try Data(contentsOf: file.url)
                for line in bytes.split(separator: 0x0A) {
                    let packet = try decoder.decode(ResearchHRSample.self, from: Data(line))
                    guard packet.rrMs.allSatisfy({ $0 >= 0 && UInt64($0) <= UInt64(UInt32.max) }) else { throw StoreError.invalidManifest }
                    packets.append(packet)
                }
            }
        }
        // Keep file order within each capture; do not deduplicate equal RR values.
        packets = packets.enumerated().sorted {
            let a = $0.element.receivedAtUnixMs ?? $0.element.receivedAt.timeIntervalSince1970 * 1000
            let b = $1.element.receivedAtUnixMs ?? $1.element.receivedAt.timeIntervalSince1970 * 1000
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        return RawH10RRRecording(phoneId: id, deviceId: first.manifest.device.deviceId,
            exerciseId: episodeId, startedAt: startedAt, stoppedAt: endedAt,
            packets: packets, metadata: first.manifest.device)
    }

    func activeSummary() -> ResearchCaptureSummary? {
        guard let capture = active else { return nil }
        let total = capture.manifest.files.reduce(UInt64(0)) { $0 + $1.byteCount }
        return ResearchCaptureSummary(
            captureId: capture.manifest.captureId,
            directory: capture.directory,
            totalBytes: total,
            fileCount: capture.manifest.files.count
        )
    }


    func pendingArchives() throws -> [ResearchCaptureArchive] {
        let root = try capturesDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [ResearchCaptureArchive] = []

        for directory in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }

            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let manifest = try decoder.decode(ResearchCaptureManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.state != "recording" else { continue }
            if active?.manifest.captureId == manifest.captureId { continue }

            let described = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.fileName, $0) })
            var files: [ResearchArchiveFile] = []

            for url in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resource.isRegularFile == true else { continue }
                let name = url.lastPathComponent
                let descriptor = described[name]
                let channel: String?
                let encoding: String?
                if name == "manifest.json" {
                    channel = "manifest"
                    encoding = "json:ResearchCaptureManifest"
                } else if name == "events.ndjson" {
                    channel = "events"
                    encoding = "ndjson:ResearchCaptureEvent"
                } else {
                    channel = descriptor?.channel
                    encoding = descriptor?.recordEncoding
                }
                files.append(
                    ResearchArchiveFile(
                        fileName: name,
                        url: url,
                        channel: channel,
                        recordEncoding: encoding,
                        byteCount: UInt64(resource.fileSize ?? 0)
                    )
                )
            }

            guard !files.isEmpty else { continue }
            result.append(
                ResearchCaptureArchive(
                    captureId: manifest.captureId,
                    directory: directory,
                    manifest: manifest,
                    files: files.sorted { $0.fileName < $1.fileName }
                )
            )
        }

        return result.sorted {
            if $0.manifest.startedAt == $1.manifest.startedAt {
                return $0.captureId.uuidString < $1.captureId.uuidString
            }
            return $0.manifest.startedAt < $1.manifest.startedAt
        }
    }

    func deleteVerifiedArchive(_ archive: ResearchCaptureArchive) throws {
        let root = try capturesDirectory().standardizedFileURL
        let directory = archive.directory.standardizedFileURL
        guard directory.deletingLastPathComponent() == root else {
            throw StoreError.invalidManifest
        }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw StoreError.invalidManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ResearchCaptureManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.captureId == archive.captureId, manifest.state != "recording" else {
            throw StoreError.invalidManifest
        }

        try FileManager.default.removeItem(at: directory)
    }

    private func appendBinary(
        channel: String,
        recordEncoding: String,
        data: Data,
        recordCount: UInt64
    ) throws {
        guard var capture = active else { throw StoreError.noActiveCapture }

        var writer = try writerFor(
            channel: channel,
            recordEncoding: recordEncoding,
            additionalBytes: UInt64(data.count),
            capture: &capture
        )

        try writer.handle.seekToEnd()
        try writer.handle.write(contentsOf: data)
        writer.bytes += UInt64(data.count)
        writer.records += recordCount
        writer.bytesSinceSync += UInt64(data.count)

        updateManifestFile(writer: writer, capture: &capture)

        // PMD packets arrive frequently. fsync/manifest-rewrite on every BLE packet
        // burns battery and can become the bottleneck overnight. Flush boundedly:
        // at most ~5 seconds or 64 KiB of newly written binary data is pending.
        let now = Date()
        if writer.bytesSinceSync >= 64 * 1024 || now.timeIntervalSince(writer.lastSyncAt) >= 5 {
            try writer.handle.synchronize()
            writer.bytesSinceSync = 0
            writer.lastSyncAt = now
            try writeManifest(capture.manifest, to: capture.manifestURL)
        }

        capture.writers[channel] = writer
        active = capture
    }

    private func writerFor(
        channel: String,
        recordEncoding: String,
        additionalBytes: UInt64,
        capture: inout ActiveCapture
    ) throws -> ChannelWriter {
        if var current = capture.writers[channel] {
            if current.bytes > 0 && current.bytes + additionalBytes > chunkLimitBytes {
                try current.handle.synchronize()
                updateManifestFile(writer: current, capture: &capture)
                try writeManifest(capture.manifest, to: capture.manifestURL)
                try current.handle.close()
                capture.writers.removeValue(forKey: channel)
                return try createWriter(
                    channel: channel,
                    recordEncoding: recordEncoding,
                    chunkIndex: current.chunkIndex + 1,
                    capture: &capture
                )
            }
            return current
        }
        return try createWriter(channel: channel, recordEncoding: recordEncoding, chunkIndex: 0, capture: &capture)
    }

    private func createWriter(
        channel: String,
        recordEncoding: String,
        chunkIndex: Int,
        capture: inout ActiveCapture
    ) throws -> ChannelWriter {
        let name = String(format: "%@-%04d.bin", channel, chunkIndex)
        let url = capture.directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            createProtectedFile(at: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let writer = ChannelWriter(
            channel: channel,
            recordEncoding: recordEncoding,
            chunkIndex: chunkIndex,
            fileURL: url,
            handle: handle,
            bytes: size,
            records: 0,
            bytesSinceSync: 0,
            lastSyncAt: Date()
        )
        capture.writers[channel] = writer
        if !capture.manifest.files.contains(where: { $0.fileName == name }) {
            capture.manifest.files.append(
                ResearchCaptureFile(
                    channel: channel,
                    fileName: name,
                    recordEncoding: recordEncoding,
                    byteCount: size,
                    recordCount: 0
                )
            )
            try writeManifest(capture.manifest, to: capture.manifestURL)
        }
        return writer
    }

    private func updateManifestFile(writer: ChannelWriter, capture: inout ActiveCapture) {
        guard let index = capture.manifest.files.firstIndex(where: { $0.fileName == writer.fileURL.lastPathComponent }) else { return }
        capture.manifest.files[index].byteCount = writer.bytes
        capture.manifest.files[index].recordCount = writer.records
    }

    private func appendLine(_ data: Data, toActiveNamedFile fileName: String, channel: String, recordEncoding: String) throws {
        guard var capture = active else { throw StoreError.noActiveCapture }
        let url = capture.directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            createProtectedFile(at: url)
            capture.manifest.files.append(
                ResearchCaptureFile(channel: channel, fileName: fileName, recordEncoding: recordEncoding, byteCount: 0, recordCount: 0)
            )
        }
        var line = data
        line.append(0x0A)
        try appendLine(line, to: url, alreadyTerminated: true)

        if let index = capture.manifest.files.firstIndex(where: { $0.fileName == fileName }) {
            capture.manifest.files[index].byteCount += UInt64(line.count)
            capture.manifest.files[index].recordCount += 1
        }
        try writeManifest(capture.manifest, to: capture.manifestURL)
        active = capture
    }

    private func appendLine(_ data: Data, to url: URL, alreadyTerminated: Bool = false) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            createProtectedFile(at: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if alreadyTerminated {
            try handle.write(contentsOf: data)
        } else {
            var line = data
            line.append(0x0A)
            try handle.write(contentsOf: line)
        }
        try handle.synchronize()
    }

    private func writeManifest(_ manifest: ResearchCaptureManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try durableWrite(data, to: url)
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        #if os(iOS)
        // Overnight capture must remain writable while the phone is locked.
        // "Complete" protection would make the file unavailable at lock time.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func createProtectedFile(at url: URL) {
        #if os(iOS)
        FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        #else
        FileManager.default.createFile(atPath: url.path, contents: nil)
        #endif
    }

    private func fixedRecordSize(for recordEncoding: String) -> Int? {
        if recordEncoding == "little_endian:uint64_timestamp_ns,int32_microvolts" { return 12 }
        if recordEncoding == "little_endian:uint64_timestamp_ns,int32_x_mg,int32_y_mg,int32_z_mg" { return 20 }
        return nil
    }

    private func finalizeCoverage(manifest: inout ResearchCaptureManifest, endedAt: Date) {
        let wallClockSeconds = max(0, endedAt.timeIntervalSince(manifest.startedAt))
        var coverage: [String: ResearchChannelCoverage] = [:]
        for descriptor in manifest.channels {
            guard let rate = descriptor.sampleRateHz, rate > 0 else { continue }
            let received = manifest.files
                .filter { $0.channel == descriptor.channel }
                .reduce(UInt64(0)) { $0 + $1.recordCount }
            let recordedSeconds = Double(received) / Double(rate)
            let denominator = wallClockSeconds * Double(rate)
            let percent = denominator > 0
                ? min(100, (Double(received) / denominator) * 100)
                : 0
            coverage[descriptor.channel] = ResearchChannelCoverage(
                expectedSampleRateHz: rate,
                receivedSamples: received,
                recordedSeconds: recordedSeconds,
                wallClockSeconds: wallClockSeconds,
                coveragePct: percent
            )
        }
        manifest.channelCoverage = coverage
        let requiredCoverage = coverage.values.map(\.coveragePct)
        if requiredCoverage.isEmpty {
            manifest.captureQuality = "no_rate_based_channels"
        } else if requiredCoverage.allSatisfy({ $0 >= 98 }) {
            manifest.captureQuality = "continuous"
        } else {
            manifest.captureQuality = "completed_with_gaps"
        }
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { raw in
            data.append(contentsOf: raw)
        }
    }
}
