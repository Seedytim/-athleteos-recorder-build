import Foundation
import CoreBluetooth
import PolarBleSdk

@MainActor
final class PolarH10Recorder: NSObject, ObservableObject {
    struct NearbyH10: Identifiable, Hashable {
        let id: String
        let name: String
        let rssi: Int
    }

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
    }

    @Published var deviceId: String {
        didSet {
            UserDefaults.standard.set(deviceId, forKey: Keys.deviceId)
        }
    }
    @Published private(set) var nearbyH10s: [NearbyH10] = []
    @Published private(set) var scanning = false
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var bluetoothOn = false
    @Published private(set) var h10RecordingFeatureReady = false
    @Published private(set) var fileTransferFeatureReady = false
    @Published private(set) var recordingOngoing = false
    @Published private(set) var fetchInProgress = false
    @Published private(set) var pftpOperationInProgress = false
    @Published private(set) var pendingFetchAvailable = false
    @Published private(set) var athleteOSUploadConfirmed = false
    @Published private(set) var batteryPercent: UInt?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var currentExerciseId: String?
    @Published private(set) var storedExerciseId: String?
    @Published private(set) var lastSavedFile: URL?
    @Published private(set) var statusText = "Tap Find nearby H10s, then choose your sensor."
    @Published private(set) var lastError: String?

    private let store = RecordingStore()
    private var storedExerciseEntry: PolarExerciseEntry?
    private var scanTask: Task<Void, Never>?
    private var fetchReconnectInProgress = false
    private var didAutoRefreshCurrentConnection = false

    private lazy var api: PolarBleApi = {
        PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue.main,
            features: [
                .feature_battery_info,
                .feature_device_info,
                .feature_polar_device_control,
                .feature_polar_file_transfer,
                .feature_polar_h10_exercise_recording
            ],
            restoreIdentifier: "nz.co.athleteos.recorder.polar"
        )
    }()

    private enum Keys {
        static let deviceId = "h10.deviceId"
        static let exerciseId = "h10.exerciseId"
        static let startedAt = "h10.startedAt"
        static let stoppedAt = "h10.stoppedAt"
        static let lastSavedFilePath = "h10.lastSavedFilePath"
        static let uploadedExerciseId = "h10.uploadedExerciseId"
    }

    override init() {
        let savedExerciseId = UserDefaults.standard.string(forKey: Keys.exerciseId)
        let savedFilePath = UserDefaults.standard.string(forKey: Keys.lastSavedFilePath)
        let uploadedExerciseId = UserDefaults.standard.string(forKey: Keys.uploadedExerciseId)
        self.deviceId = UserDefaults.standard.string(forKey: Keys.deviceId) ?? ""
        self.currentExerciseId = savedExerciseId
        self.pendingFetchAvailable = savedExerciseId != nil
        if let savedFilePath, FileManager.default.fileExists(atPath: savedFilePath) {
            self.lastSavedFile = URL(fileURLWithPath: savedFilePath)
        }
        self.athleteOSUploadConfirmed =
            savedExerciseId != nil && uploadedExerciseId == savedExerciseId
        super.init()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            bluetoothOn = true
            connectionState = .connected
            h10RecordingFeatureReady = true
            fileTransferFeatureReady = true
            batteryPercent = 82
            currentExerciseId = nil
            pendingFetchAvailable = false
            lastSavedFile = nil
            athleteOSUploadConfirmed = false
            return
        }
        #endif

        api.observer = self
        api.powerStateObserver = self
        api.deviceFeaturesObserver = self
        api.deviceInfoObserver = self
        api.polarFilter(true)
        bluetoothOn = api.isBlePowered
    }

    deinit {
        scanTask?.cancel()
    }

    func startScanning() {
        clearError()
        guard bluetoothOn else {
            fail("Turn Bluetooth on, then try again.")
            return
        }
        guard connectionState == .disconnected else {
            fail("Disconnect the current H10 before scanning.")
            return
        }

        stopScanning()
        nearbyH10s = []
        scanning = true
        statusText = "Looking for nearby Polar H10 sensors…"

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await device in self.api.searchForDevice(withRequiredDeviceNamePrefix: "Polar") {
                    if Task.isCancelled { break }

                    let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard name.uppercased().contains("H10"), device.connectable else { continue }

                    let found = NearbyH10(id: device.deviceId, name: name, rssi: device.rssi)
                    if let index = self.nearbyH10s.firstIndex(where: { $0.id == found.id }) {
                        self.nearbyH10s[index] = found
                    } else {
                        self.nearbyH10s.append(found)
                    }
                    self.nearbyH10s.sort { $0.rssi > $1.rssi }
                    self.statusText = self.nearbyH10s.count == 1
                        ? "Found 1 nearby H10. Tap it to connect."
                        : "Found \(self.nearbyH10s.count) nearby H10s. Tap yours to connect."
                }
            } catch {
                if !Task.isCancelled {
                    self.fail("H10 scan failed: \(error.localizedDescription)")
                }
            }

            if !Task.isCancelled {
                self.scanning = false
                if self.nearbyH10s.isEmpty && self.lastError == nil {
                    self.statusText = "No H10 found. Make sure the strap is wet and being worn, then scan again."
                }
            }
        }
    }

    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }

    func connect(to h10: NearbyH10) {
        stopScanning()
        deviceId = h10.id
        connect()
    }

    func connect() {
        clearError()
        let trimmed = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail("Scan for your Polar H10 first.")
            return
        }

        stopScanning()
        connectionState = .connecting
        h10RecordingFeatureReady = false
        fileTransferFeatureReady = false
        didAutoRefreshCurrentConnection = false
        statusText = "Connecting to H10 \(trimmed)…"

        do {
            try api.connectToDevice(trimmed)
        } catch {
            connectionState = .disconnected
            fail("Connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        clearError()
        guard !deviceId.isEmpty else { return }
        do {
            try api.disconnectFromDevice(deviceId)
            statusText = recordingOngoing
                ? "Phone disconnected. H10 should continue its internal RR recording."
                : "Disconnected."
        } catch {
            fail("Disconnect failed: \(error.localizedDescription)")
        }
    }

    func refreshRecordingStatus() async {
        guard !fetchInProgress, !pftpOperationInProgress else {
            statusText = "H10 is busy with another file/recording operation."
            return
        }
        clearError()
        guard h10RecordingFeatureReady else {
            fail("H10 recording feature is not ready yet.")
            return
        }

        pftpOperationInProgress = true
        defer { pftpOperationInProgress = false }

        do {
            let status = try await api.requestRecordingStatus(deviceId)
            recordingOngoing = status.ongoing
            if status.ongoing, !status.entryId.isEmpty {
                currentExerciseId = status.entryId
                pendingFetchAvailable = true
                UserDefaults.standard.set(status.entryId, forKey: Keys.exerciseId)
            }
            statusText = status.ongoing
                ? "H10 internal RR recording is running."
                : "H10 is connected and not recording."
        } catch {
            fail("Recording status failed: \(error.localizedDescription)")
        }
    }

    func startRRRecordingAndReleasePhone() async {
        guard !fetchInProgress, !pftpOperationInProgress else {
            statusText = "H10 is busy with another file/recording operation."
            return
        }
        clearError()
        guard h10RecordingFeatureReady else {
            fail("H10 recording feature is not ready yet.")
            return
        }

        pftpOperationInProgress = true
        defer { pftpOperationInProgress = false }

        do {
            let existing = try await api.requestRecordingStatus(deviceId)
            guard !existing.ongoing else {
                recordingOngoing = true
                currentExerciseId = existing.entryId
                pendingFetchAvailable = true
                fail("The H10 already has an active recording. Stop/fetch it before starting another.")
                return
            }

            let exerciseId = "AOS_\(Int(Date().timeIntervalSince1970))"
            let startedAt = Date()

            try await api.startRecording(
                deviceId,
                exerciseId: exerciseId,
                interval: .interval_1s,
                sampleType: .rr
            )

            let confirmed = try await api.requestRecordingStatus(deviceId)
            guard confirmed.ongoing else {
                fail("Polar accepted the start request but status did not confirm an active recording.")
                return
            }

            recordingOngoing = true
            currentExerciseId = confirmed.entryId.isEmpty ? exerciseId : confirmed.entryId
            pendingFetchAvailable = true
            storedExerciseEntry = nil
            storedExerciseId = nil
            lastSavedFile = nil
            athleteOSUploadConfirmed = false
            UserDefaults.standard.removeObject(forKey: Keys.lastSavedFilePath)
            UserDefaults.standard.removeObject(forKey: Keys.uploadedExerciseId)
            UserDefaults.standard.set(currentExerciseId, forKey: Keys.exerciseId)
            UserDefaults.standard.set(startedAt, forKey: Keys.startedAt)
            UserDefaults.standard.removeObject(forKey: Keys.stoppedAt)
            statusText = "RR recording confirmed. Disconnecting phone; H10 remains the primary recorder."

            do {
                try api.disconnectFromDevice(deviceId)
            } catch {
                statusText = "RR recording confirmed. Automatic phone disconnect failed; recording should still be active."
            }
        } catch {
            fail("Start RR recording failed: \(error.localizedDescription)")
        }
    }

    func stopFetchAndSave() async {
        clearError()
        guard h10RecordingFeatureReady else {
            fail("Reconnect and wait until the H10 recording feature is ready.")
            return
        }
        guard !fetchInProgress, !pftpOperationInProgress else { return }

        fetchInProgress = true
        pftpOperationInProgress = true
        defer {
            fetchInProgress = false
            pftpOperationInProgress = false
        }

        do {
            let status = try await api.requestRecordingStatus(deviceId)
            var stoppedAt = UserDefaults.standard.object(forKey: Keys.stoppedAt) as? Date

            if status.ongoing {
                statusText = "Stopping H10 recording…"
                try await api.stopRecording(deviceId)
                recordingOngoing = false
                stoppedAt = Date()
                UserDefaults.standard.set(stoppedAt, forKey: Keys.stoppedAt)

                // Give the H10 time to finalize the exercise file before PS-FTP reads it.
                statusText = "Recording stopped. Finalizing stored RR file…"
                try await Task.sleep(for: .seconds(2))
            } else {
                recordingOngoing = false
            }

            pendingFetchAvailable = true

            // Polar H10 firmware 5.0.0 can leave the PFTP session in a state where
            // stored-exercise reads return ResponseError 106 immediately after stop.
            // A clean BLE disconnect/reconnect resets that session reliably.
            try await resetConnectionForStoredFetch()
            await fetchAndSaveStoredRecording(stoppedAt: stoppedAt ?? Date())
        } catch {
            pendingFetchAvailable = true
            fail("Stop/fetch/save failed: \(friendlyError(error)). Sensor copy retained; use Retry Fetch.")
        }
    }

    func retryFetchAndSave() async {
        clearError()
        guard h10RecordingFeatureReady else {
            fail("Reconnect and wait until the H10 recording feature is ready.")
            return
        }
        guard !fetchInProgress, !pftpOperationInProgress else { return }

        fetchInProgress = true
        pftpOperationInProgress = true
        defer {
            fetchInProgress = false
            pftpOperationInProgress = false
        }

        let stoppedAt = (UserDefaults.standard.object(forKey: Keys.stoppedAt) as? Date) ?? Date()

        do {
            try await resetConnectionForStoredFetch()
            await fetchAndSaveStoredRecording(stoppedAt: stoppedAt)
        } catch {
            pendingFetchAvailable = true
            fail("Reconnect for fetch failed: \(friendlyError(error)). Sensor copy retained.")
        }
    }

    private func resetConnectionForStoredFetch() async throws {
        fetchReconnectInProgress = true
        defer { fetchReconnectInProgress = false }

        statusText = "Resetting H10 connection for stored-file transfer…"

        if connectionState != .disconnected {
            do {
                try api.disconnectFromDevice(deviceId)
            } catch {
                // If the SDK already considers the link down, the observer/poll below
                // will settle to disconnected. Only fail if it never does.
            }

            for _ in 0..<60 {
                if connectionState == .disconnected { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        guard connectionState == .disconnected else {
            throw NSError(
                domain: "AthleteOSRecorder",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "H10 did not disconnect cleanly before stored-file transfer."]
            )
        }

        h10RecordingFeatureReady = false
        fileTransferFeatureReady = false
        didAutoRefreshCurrentConnection = false
        connectionState = .connecting
        statusText = "Reconnecting H10 for stored-file transfer…"

        do {
            try api.connectToDevice(deviceId)
        } catch {
            connectionState = .disconnected
            throw error
        }

        for _ in 0..<150 {
            if connectionState == .connected && h10RecordingFeatureReady && fileTransferFeatureReady {
                // Do not launch requestRecordingStatus here. It uses the same PFTP
                // transport as list/fetch and can collide with the stored-file read.
                statusText = "H10 file transfer ready. Settling connection…"
                try await Task.sleep(for: .milliseconds(1200))
                statusText = "H10 reconnected. Reading stored RR recording…"
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw NSError(
            domain: "AthleteOSRecorder",
            code: 1002,
            userInfo: [NSLocalizedDescriptionKey: "H10 file-transfer service did not become ready after reconnect."]
        )
    }

    private func fetchAndSaveStoredRecording(stoppedAt: Date) async {
        let maxAttempts = 5
        let retryDelays: [UInt64] = [1, 2, 4, 7]

        for attempt in 1...maxAttempts {
            do {
                let expectedId = currentExerciseId ?? UserDefaults.standard.string(forKey: Keys.exerciseId)

                if let expectedId, !expectedId.isEmpty {
                    // For H10 recordings the exercise identifier becomes the directory name.
                    // Avoid listExercises() here: it recursively walks the entire H10 filesystem
                    // and can stall indefinitely on some firmware/PFTP states.
                    let directEntry: PolarExerciseEntry = (
                        path: "/\(expectedId)/SAMPLES.BPB",
                        date: stoppedAt,
                        entryId: expectedId
                    )
                    storedExerciseEntry = directEntry
                    storedExerciseId = expectedId
                    statusText = attempt == 1
                        ? "Reading saved RR file directly from H10…"
                        : "Retrying direct H10 RR read (\(attempt)/\(maxAttempts))…"

                    do {
                        let exercise = try await fetchExerciseWithTimeout(directEntry, seconds: 15)
                        try await persistFetchedExercise(exercise, entry: directEntry, stoppedAt: stoppedAt)
                        return
                    } catch {
                        if (isOperationNotPermitted106(error) || isPftpTimeout(error)), attempt < maxAttempts {
                            let delay = retryDelays[min(attempt - 1, retryDelays.count - 1)]
                            statusText = isPftpTimeout(error)
                                ? "H10 RR read timed out. Resetting connection in \(delay)s…"
                                : "H10 refused the direct RR read (Polar 106). Resetting connection in \(delay)s…"
                            try await Task.sleep(for: .seconds(delay))
                            try await resetConnectionForStoredFetch()
                            continue
                        }

                        // A direct path miss or other read failure may mean this recording came
                        // from an older naming scheme. Fall through to one bounded directory scan.
                        statusText = "Direct H10 read did not complete. Trying a bounded file lookup…"
                    }
                }

                let entries = try await listExercisesWithTimeout(seconds: 12)
                guard !entries.isEmpty else {
                    throw NSError(
                        domain: "AthleteOSRecorder",
                        code: 1003,
                        userInfo: [NSLocalizedDescriptionKey: "No stored H10 exercise was found."]
                    )
                }

                let fallbackExpectedId = currentExerciseId ?? UserDefaults.standard.string(forKey: Keys.exerciseId)
                let entry = entries.first(where: { $0.entryId == fallbackExpectedId }) ?? entries.last!
                storedExerciseEntry = entry
                storedExerciseId = entry.entryId
                statusText = "Stored RR file found. Reading H10…"

                let exercise = try await fetchExerciseWithTimeout(entry, seconds: 15)
                try await persistFetchedExercise(exercise, entry: entry, stoppedAt: stoppedAt)
                return
            } catch {
                if attempt < maxAttempts {
                    let delay = retryDelays[min(attempt - 1, retryDelays.count - 1)]
                    statusText = "H10 file read did not finish. Resetting connection in \(delay)s…"
                    try? await Task.sleep(for: .seconds(delay))
                    do {
                        try await resetConnectionForStoredFetch()
                    } catch {
                        pendingFetchAvailable = true
                        fail("H10 reconnect failed: \(friendlyError(error)). Sensor copy retained.")
                        return
                    }
                    continue
                }

                pendingFetchAvailable = true
                fail("Fetch failed after \(maxAttempts) clean reconnects: \(friendlyError(error)). Sensor copy retained.")
                return
            }
        }
    }

    private func persistFetchedExercise(
        _ exercise: PolarExerciseData,
        entry: PolarExerciseEntry,
        stoppedAt: Date
    ) async throws {
        let startedAt = UserDefaults.standard.object(forKey: Keys.startedAt) as? Date
        let fetchedAt = Date()

        let raw = RawH10RRRecording(
            deviceId: deviceId,
            exerciseId: entry.entryId,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            fetchedAt: fetchedAt,
            polarSdkVersion: PolarBleApiDefaultImpl.versionInfo(),
            firmwareVersion: firmwareVersion,
            batteryPercentAtFetch: batteryPercent,
            recordingIntervalSeconds: exercise.interval,
            rrSamplesRaw: exercise.samples
        )

        let file = try await store.save(raw)
        lastSavedFile = file
        UserDefaults.standard.set(file.path, forKey: Keys.lastSavedFilePath)
        athleteOSUploadConfirmed = false
        UserDefaults.standard.removeObject(forKey: Keys.uploadedExerciseId)
        pendingFetchAvailable = false
        clearError()
        statusText = "Saved \(exercise.samples.count) raw RR samples. Sensor copy retained."
    }

    private func listExercisesWithTimeout(seconds: UInt64) async throws -> [PolarExerciseEntry] {
        try await withThrowingTaskGroup(of: [PolarExerciseEntry].self) { group in
            group.addTask { [api, deviceId] in
                var entries: [PolarExerciseEntry] = []
                for try await entry in api.listExercises(deviceId) {
                    entries.append(entry)
                }
                return entries
            }
            group.addTask { [api, deviceId] in
                try await Task.sleep(for: .seconds(seconds))
                try? api.disconnectFromDevice(deviceId)
                throw NSError(
                    domain: "AthleteOSRecorder",
                    code: 1004,
                    userInfo: [NSLocalizedDescriptionKey: "H10 file listing timed out; connection reset."]
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NSError(
                    domain: "AthleteOSRecorder",
                    code: 1005,
                    userInfo: [NSLocalizedDescriptionKey: "H10 file listing ended unexpectedly."]
                )
            }
            return result
        }
    }

    private func fetchExerciseWithTimeout(
        _ entry: PolarExerciseEntry,
        seconds: UInt64
    ) async throws -> PolarExerciseData {
        try await withThrowingTaskGroup(of: PolarExerciseData.self) { group in
            group.addTask { [api, deviceId] in
                try await api.fetchExercise(deviceId, entry: entry)
            }
            group.addTask { [api, deviceId] in
                try await Task.sleep(for: .seconds(seconds))
                try? api.disconnectFromDevice(deviceId)
                throw NSError(
                    domain: "AthleteOSRecorder",
                    code: 1006,
                    userInfo: [NSLocalizedDescriptionKey: "H10 RR file read timed out; connection reset."]
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NSError(
                    domain: "AthleteOSRecorder",
                    code: 1007,
                    userInfo: [NSLocalizedDescriptionKey: "H10 RR file read ended unexpectedly."]
                )
            }
            return result
        }
    }

    func markAthleteOSUploadConfirmed(for file: URL) {
        guard let lastSavedFile, lastSavedFile.standardizedFileURL == file.standardizedFileURL else { return }
        let exerciseId = storedExerciseId ?? currentExerciseId ?? UserDefaults.standard.string(forKey: Keys.exerciseId)
        guard let exerciseId else { return }
        athleteOSUploadConfirmed = true
        UserDefaults.standard.set(exerciseId, forKey: Keys.uploadedExerciseId)
        statusText = "Saved locally and confirmed in AthleteOS. H10 copy can now be deleted."
    }

    func deleteSensorCopy() async {
        guard !fetchInProgress, !pftpOperationInProgress else {
            statusText = "H10 is busy with another file/recording operation."
            return
        }
        clearError()
        guard lastSavedFile != nil else {
            fail("A verified local save is required before deleting the H10 copy.")
            return
        }
        guard athleteOSUploadConfirmed else {
            fail("AthleteOS must confirm the upload before the H10 copy can be deleted.")
            return
        }

        pftpOperationInProgress = true
        defer { pftpOperationInProgress = false }

        do {
            var entry = storedExerciseEntry
            if entry == nil {
                let expectedId =
                    storedExerciseId ??
                    currentExerciseId ??
                    UserDefaults.standard.string(forKey: Keys.exerciseId)
                var entries: [PolarExerciseEntry] = []
                for try await candidate in api.listExercises(deviceId) {
                    entries.append(candidate)
                }
                entry = entries.first(where: { $0.entryId == expectedId })
            }

            guard let entry else {
                fail("The saved H10 recording could not be found for deletion. Local and AthleteOS copies are retained.")
                return
            }

            try await api.removeExercise(deviceId, entry: entry)
            storedExerciseEntry = nil
            storedExerciseId = nil
            currentExerciseId = nil
            pendingFetchAvailable = false
            athleteOSUploadConfirmed = false
            UserDefaults.standard.removeObject(forKey: Keys.exerciseId)
            UserDefaults.standard.removeObject(forKey: Keys.startedAt)
            UserDefaults.standard.removeObject(forKey: Keys.stoppedAt)
            UserDefaults.standard.removeObject(forKey: Keys.uploadedExerciseId)
            statusText = "Sensor copy deleted. Local raw file and AthleteOS copy retained."
        } catch {
            fail("Delete sensor copy failed: \(error.localizedDescription)")
        }
    }

    private func isOperationNotPermitted106(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 106 { return true }

        let text = "\(error) \(error.localizedDescription)".lowercased()
        return text.contains("error 106")
            || text.contains("errorcode: 106")
            || text.contains("responseerror(errorcode: 106)")
            || text.contains("operation_not_permitted")
            || text.contains("operation not permitted")
    }

    private func isPftpTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "AthleteOSRecorder" && [1004, 1005, 1006, 1007].contains(nsError.code)
    }

    private func friendlyError(_ error: Error) -> String {
        if isOperationNotPermitted106(error) {
            return "Polar PFTP 106 (operation not permitted)"
        }
        return error.localizedDescription
    }

    private func clearError() {
        lastError = nil
    }

    private func fail(_ message: String) {
        lastError = message
        statusText = message
    }
}

extension PolarH10Recorder: PolarBleApiObserver {
    nonisolated func deviceConnecting(_ identifier: PolarDeviceInfo) {
        Task { @MainActor in
            self.connectionState = .connecting
            self.h10RecordingFeatureReady = false
            self.fileTransferFeatureReady = false
            self.didAutoRefreshCurrentConnection = false
            self.statusText = "Connecting to \(identifier.deviceId)…"
        }
    }

    nonisolated func deviceConnected(_ identifier: PolarDeviceInfo) {
        Task { @MainActor in
            self.stopScanning()
            self.deviceId = identifier.deviceId
            self.connectionState = .connected
            self.statusText = "Connected. Waiting for H10 recording feature…"
        }
    }

    nonisolated func deviceDisconnected(_ identifier: PolarDeviceInfo, info: PolarBleDisconnectInfo) {
        Task { @MainActor in
            self.connectionState = .disconnected
            self.h10RecordingFeatureReady = false
            self.fileTransferFeatureReady = false
            self.didAutoRefreshCurrentConnection = false
            if self.recordingOngoing {
                self.statusText = "Phone disconnected; H10 sensor-side recording remains the source of truth."
            } else {
                self.statusText = "Disconnected."
            }
        }
    }
}

extension PolarH10Recorder: PolarBleApiPowerStateObserver {
    nonisolated func blePowerOn() {
        Task { @MainActor in
            self.bluetoothOn = true
        }
    }

    nonisolated func blePowerOff() {
        Task { @MainActor in
            self.stopScanning()
            self.bluetoothOn = false
            self.connectionState = .disconnected
            self.h10RecordingFeatureReady = false
            self.statusText = "Bluetooth is off."
        }
    }
}

extension PolarH10Recorder: PolarBleApiDeviceFeaturesObserver {
    nonisolated func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        Task { @MainActor in
            switch feature {
            case .feature_polar_h10_exercise_recording:
                self.h10RecordingFeatureReady = true
            case .feature_polar_file_transfer:
                self.fileTransferFeatureReady = true
            default:
                return
            }

            guard
                self.connectionState == .connected,
                self.h10RecordingFeatureReady,
                self.fileTransferFeatureReady
            else {
                return
            }

            if self.fetchReconnectInProgress {
                self.statusText = "H10 recording and file-transfer services ready."
                return
            }

            // Do not automatically issue requestRecordingStatus here.
            // Polar recording status and exercise file access share the PFTP request
            // queue; auto-refresh can overlap a user-initiated fetch and cause the
            // SDK AtomicList waitTimeout seen on H10 firmware 5.0.0.
            self.statusText = "H10 ready. Refresh status only when needed."
        }
    }
}

extension PolarH10Recorder: PolarBleApiDeviceInfoObserver {
    nonisolated func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        Task { @MainActor in
            self.batteryPercent = batteryLevel
        }
    }

    nonisolated func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {}

    nonisolated func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        guard uuid == CBUUID(string: "2A26") else { return }
        Task { @MainActor in
            self.firmwareVersion = value.replacingOccurrences(of: "\u{0000}", with: "")
        }
    }

    nonisolated func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        guard key.uppercased() == "2A26" || key.uppercased().contains("FIRMWARE") else { return }
        Task { @MainActor in
            self.firmwareVersion = value.replacingOccurrences(of: "\u{0000}", with: "")
        }
    }
}
