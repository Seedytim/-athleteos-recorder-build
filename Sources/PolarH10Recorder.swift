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
    @Published private(set) var nightActionInProgress = false
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var bluetoothOn = false
    @Published private(set) var h10RecordingFeatureReady = false
    @Published private(set) var fileTransferFeatureReady = false
    @Published private(set) var onlineStreamingFeatureReady = false
    @Published private(set) var hrFeatureReady = false
    @Published private(set) var rawStreamActive = false
    @Published private(set) var rawStreamStatus = "Idle"
    @Published private(set) var rawCaptureBytes: UInt64 = 0
    @Published private(set) var preparationTimedOut = false
    @Published private(set) var recoveringConnection = false
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
    @Published private(set) var pendingSensorCleanupCount = 0
    @Published private(set) var statusText = "Tap Find nearby H10s, then choose your sensor."
    @Published private(set) var lastError: String?

    private let store = RecordingStore.shared
    private let researchStore = ResearchCaptureStore.shared
    private var storedExerciseEntry: PolarExerciseEntry?
    private var ecgStreamTask: Task<Void, Never>?
    private var accStreamTask: Task<Void, Never>?
    private var hrStreamTask: Task<Void, Never>?
    private var researchReconnectTask: Task<Void, Never>?
    private var ecgStreamRunning = false
    private var accStreamRunning = false
    private var hrStreamRunning = false
    private var lastECGAnchorAt: Date?
    private var lastACCAnchorAt: Date?
    private var rawCaptureExpected = false
    private var scanTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var fetchReconnectInProgress = false
    private var didAutoRefreshCurrentConnection = false

    private lazy var api: PolarBleApi = {
        PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue.main,
            features: [
                .feature_battery_info,
                .feature_device_info,
                .feature_hr,
                .feature_polar_online_streaming,
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
        static let pendingSensorCleanupIds = "h10.pendingSensorCleanupIds"
        static let rawCaptureExpected = "h10.rawCaptureExpected"
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
            self.pendingFetchAvailable = false
        }
        self.athleteOSUploadConfirmed =
            savedExerciseId != nil && uploadedExerciseId == savedExerciseId
        self.pendingSensorCleanupCount =
            (UserDefaults.standard.stringArray(forKey: Keys.pendingSensorCleanupIds) ?? []).count
        self.rawCaptureExpected = UserDefaults.standard.bool(forKey: Keys.rawCaptureExpected)
        super.init()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            bluetoothOn = true
            connectionState = .connected
            h10RecordingFeatureReady = true
            fileTransferFeatureReady = true
            onlineStreamingFeatureReady = true
            hrFeatureReady = true
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

        Task { [researchStore] in
            _ = try? await researchStore.recoverInterruptedCaptures()
        }
    }

    deinit {
        preparationTask?.cancel()
        scanTask?.cancel()
        ecgStreamTask?.cancel()
        accStreamTask?.cancel()
        hrStreamTask?.cancel()
        researchReconnectTask?.cancel()
    }

    func prepareRawCaptureRecovery() async {
        do {
            let recovered = try await researchStore.recoverInterruptedCaptures()
            if recovered > 0 {
                rawStreamStatus = "Previous high-resolution chunks retained after interruption"
            }
        } catch {
            rawStreamStatus = "Raw recovery warning: \(error.localizedDescription)"
        }

        guard rawCaptureExpected, let expectedExercise = currentExerciseId, bluetoothOn else { return }

        if connectionState == .disconnected {
            connect()
        }

        // A relaunch may occur while the independent H10 RR exercise is still running.
        // Re-establish that fact before restarting PMD streams; never infer it from
        // UserDefaults alone.
        for _ in 0..<150 {
            if connectionState == .connected && h10RecordingFeatureReady && fileTransferFeatureReady { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard connectionState == .connected, h10RecordingFeatureReady, fileTransferFeatureReady,
              !nightActionInProgress, !fetchInProgress, !pftpOperationInProgress else { return }

        pftpOperationInProgress = true
        defer { pftpOperationInProgress = false }

        do {
            let status = try await requestStatusWithTimeout()
            recordingOngoing = status.ongoing
            guard status.ongoing else {
                rawCaptureExpected = false
                UserDefaults.standard.set(false, forKey: Keys.rawCaptureExpected)
                rawStreamStatus = "Previous raw stream segment retained"
                return
            }

            guard status.entryId == expectedExercise else {
                try? await researchStore.appendEvent(
                    kind: "recovery_identity_mismatch",
                    detail: "Expected \(expectedExercise), H10 reported \(status.entryId). No high-resolution stream was restarted."
                )
                rawStreamStatus = "RR identity needs review"
                return
            }

            pendingFetchAvailable = true
            let startedAt = UserDefaults.standard.object(forKey: Keys.startedAt) as? Date ?? Date()
            await startResearchCapture(exerciseId: expectedExercise, startedAt: startedAt)
        } catch {
            rawStreamStatus = "RR remains safe · high-resolution recovery failed"
        }
    }

    /// One operation owns connection, service preparation and the sensor transaction.
    /// Archive/upload is independent: a network outage must not prevent another night.
    func performNightAction() async {
        guard !nightActionInProgress, !fetchInProgress, !pftpOperationInProgress else { return }
        if deviceId.isEmpty { startScanning(); return }
        let requestedEnd = recordingOngoing || pendingFetchAvailable
        nightActionInProgress = true
        defer { nightActionInProgress = false }
        clearError()
        await reconcileArchivedNight()
        guard await ensureReadyForNightAction() else { return }
        // Restore a save completed just before a crash, before touching H10 storage.
        if let id = currentExerciseId, let files = try? await store.list() {
            for file in files {
                if let identity = try? await store.sensorIdentity(for: file.url),
                   identity.deviceId == deviceId, identity.exerciseId == id {
                    lastSavedFile = file.url
                    UserDefaults.standard.set(file.url.path, forKey: Keys.lastSavedFilePath)
                    pendingFetchAvailable = false
                    break
                }
            }
        }
        switch NightActionPolicy.afterRecovery(requestedEnd: requestedEnd, recordingOngoing: recordingOngoing, pendingFetch: pendingFetchAvailable) {
        case .end:
            await stopFetchAndSave()
        case .archiveSaved:
            // A crash may leave a durable save/receipt ahead of UserDefaults.
            // An End press completes that night; it must never start another one.
            statusText = "Night already saved. Completing archive cleanup…"
        case .start:
            await startRRRecordingAndReleasePhone()
        }
    }

    func reconcileArchivedNight() async {
        do {
            let jobs = try await store.readySensorCleanups()
            pendingSensorCleanupCount = jobs.count
            if !recordingOngoing, jobs.contains(where: { $0.identity.deviceId == deviceId && $0.identity.exerciseId == currentExerciseId }) {
                currentExerciseId = nil
                pendingFetchAvailable = false
                UserDefaults.standard.removeObject(forKey: Keys.exerciseId)
                UserDefaults.standard.removeObject(forKey: Keys.startedAt)
                UserDefaults.standard.removeObject(forKey: Keys.stoppedAt)
            }
            if let file = lastSavedFile, !FileManager.default.fileExists(atPath: file.path) {
                lastSavedFile = nil
                UserDefaults.standard.removeObject(forKey: Keys.lastSavedFilePath)
            }
        } catch {
            fail("Verified archive cleanup will retry. Retained copies have not been discarded: \(error.localizedDescription)")
        }
    }

    private func ensureReadyForNightAction() async -> Bool {
        guard bluetoothOn else { fail("Turn on Bluetooth, then try again. Your recording is retained."); return false }
        if connectionState == .disconnected { connect() }
        for attempt in 0..<2 {
            for tick in 0...300 {
                if Task.isCancelled { return false }
                let step = NightConnectionPolicy.next(
                    bluetoothOn: bluetoothOn, connected: connectionState == .connected,
                    recordingReady: h10RecordingFeatureReady, transferReady: fileTransferFeatureReady,
                    transportBusy: pftpOperationInProgress, preparationTimedOut: preparationTimedOut,
                    deadlineReached: tick == 300, attempt: attempt
                )
                if step == .ready { return true }
                if step == .failed { break }
                if step == .reconnect { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            }
            if attempt == 0 && bluetoothOn { await retryPreparation() }
        }
        // Cancel a connection which never reached services, so the next tap can retry.
        try? api.disconnectFromDevice(deviceId)
        connectionState = .disconnected
        h10RecordingFeatureReady = false
        fileTransferFeatureReady = false
        fail("H10 could not become ready. Wear the moistened strap and keep it nearby, then try again. Sensor data is retained.")
        return false
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
                        let previous = self.nearbyH10s[index]
                        guard previous.name != found.name || abs(previous.rssi - found.rssi) >= 5 else { continue }
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
        guard !nightActionInProgress, !pendingFetchAvailable, !recordingOngoing else {
            fail("Finish saving the current H10 night before changing sensors.")
            return
        }
        stopScanning()
        deviceId = h10.id
        connect()
    }

    func connect() {
        preparationTask?.cancel()
        preparationTimedOut = false
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
        onlineStreamingFeatureReady = false
        hrFeatureReady = false
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
        preparationTask?.cancel()
        preparationTimedOut = false
        clearError()
        guard !deviceId.isEmpty else { return }
        Task {
            if rawCaptureExpected || rawStreamActive {
                await stopResearchCapture(reason: "manual_disconnect")
            }
            do {
                try api.disconnectFromDevice(deviceId)
                statusText = recordingOngoing
                    ? "Phone disconnected. H10 internal RR continues safely."
                    : "Disconnected."
            } catch {
                fail("Disconnect failed: \(error.localizedDescription)")
            }
        }
    }

    var preparationMessage: String {
        if h10RecordingFeatureReady && fileTransferFeatureReady { return "H10 services are ready." }
        let service = !h10RecordingFeatureReady ? "recording service" : "file-transfer service"
        return preparationTimedOut
            ? "The H10 connected, but its \(service) did not become ready. Reconnect to try again."
            : "Connected. Waiting for the H10 \(service)…"
    }

    private func watchPreparation() {
        preparationTask?.cancel()
        preparationTimedOut = false
        guard !fetchReconnectInProgress else { return }
        preparationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.connectionState == .connected,
                  !self.h10RecordingFeatureReady || !self.fileTransferFeatureReady,
                  !self.fetchInProgress, !self.pftpOperationInProgress else { return }
            self.preparationTimedOut = true
            self.statusText = self.preparationMessage
        }
    }

    func retryPreparation() async {
        guard !recoveringConnection, !fetchInProgress, !pftpOperationInProgress else { return }
        recoveringConnection = true
        defer { recoveringConnection = false }
        preparationTask?.cancel()
        preparationTimedOut = false
        clearError()
        do {
            try api.disconnectFromDevice(deviceId)
            for _ in 0..<60 {
                if connectionState == .disconnected { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard connectionState == .disconnected else {
                preparationTimedOut = true
                fail("The H10 did not disconnect. Try Disconnect in Settings, then reconnect.")
                return
            }
            connect()
        } catch {
            preparationTimedOut = true
            fail("Reconnect failed: \(error.localizedDescription)")
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
            let status = try await requestStatusWithTimeout()
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
            let existing = try await requestStatusWithTimeout()
            guard !existing.ongoing else {
                recordingOngoing = true
                currentExerciseId = existing.entryId
                UserDefaults.standard.set(existing.entryId, forKey: Keys.exerciseId)
                pendingFetchAvailable = true
                fail("The H10 already has an active recording. Stop/fetch it before starting another.")
                return
            }

            let exerciseId = "AOS_\(Int(Date().timeIntervalSince1970))"
            let startedAt = Date()

            // Persist the intended identity before the remote write. If its response
            // is lost, reopening presents End night, never an unsafe replacement start.
            currentExerciseId = exerciseId
            pendingFetchAvailable = true
            UserDefaults.standard.set(exerciseId, forKey: Keys.exerciseId)
            UserDefaults.standard.set(startedAt, forKey: Keys.startedAt)
            UserDefaults.standard.removeObject(forKey: Keys.stoppedAt)
            UserDefaults.standard.removeObject(forKey: Keys.lastSavedFilePath)
            lastSavedFile = nil
            let sensorAPI = api
            let sensorId = deviceId
            _ = try await boundedSensorOperation {
                try await sensorAPI.startRecording(sensorId, exerciseId: exerciseId, interval: .interval_1s, sampleType: .rr)
                return true
            }

            let confirmed = try await requestStatusWithTimeout()
            guard confirmed.supported, confirmed.ongoing, confirmed.entryId == exerciseId else {
                fail("H10 did not confirm this night's recording identity. Recovery information is retained; use End night to check it.")
                return
            }

            recordingOngoing = true
            currentExerciseId = exerciseId
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
            statusText = "H10 raw RR confirmed. Starting high-resolution raw streams…"
            await startResearchCapture(exerciseId: exerciseId, startedAt: startedAt)

            if rawStreamActive {
                statusText = "Recording raw RR + ECG + accelerometer."
            } else {
                statusText = "H10 raw RR is safe. High-resolution stream is unavailable; the safety recording continues."
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

        await stopResearchCapture(reason: "end_recording")

        fetchInProgress = true
        pftpOperationInProgress = true
        defer {
            fetchInProgress = false
            pftpOperationInProgress = false
        }

        do {
            let status = try await requestStatusWithTimeout()
            var stoppedAt = UserDefaults.standard.object(forKey: Keys.stoppedAt) as? Date

            if status.ongoing {
                guard !status.entryId.isEmpty else {
                    throw NSError(domain: "AthleteOSRecorder", code: 1008, userInfo: [NSLocalizedDescriptionKey: "H10 did not identify its active recording. No data was deleted."])
                }
                currentExerciseId = status.entryId
                pendingFetchAvailable = true
                UserDefaults.standard.set(status.entryId, forKey: Keys.exerciseId)
                statusText = "Stopping H10 recording…"
                let sensorAPI = api
                let sensorId = deviceId
                _ = try await boundedSensorOperation {
                    try await sensorAPI.stopRecording(sensorId)
                    return true
                }
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
        onlineStreamingFeatureReady = false
        hrFeatureReady = false
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
                        let exercise = try await fetchExerciseWithTimeout(directEntry, seconds: 120)
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
                guard let entry = entries.first(where: { $0.entryId == fallbackExpectedId }) else {
                    throw NSError(domain: "AthleteOSRecorder", code: 1009, userInfo: [NSLocalizedDescriptionKey: "The expected night was not found. Other H10 files were left untouched."])
                }
                storedExerciseEntry = entry
                storedExerciseId = entry.entryId
                statusText = "Stored RR file found. Reading H10…"

                let exercise = try await fetchExerciseWithTimeout(entry, seconds: 120)
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

    func markArchiveConfirmedAndLocalDeleted(for file: URL, identity: SensorRecordingIdentity?) {
        if let lastSavedFile, lastSavedFile.standardizedFileURL == file.standardizedFileURL {
            self.lastSavedFile = nil
            UserDefaults.standard.removeObject(forKey: Keys.lastSavedFilePath)
        }
        if let identity, currentExerciseId == identity.exerciseId, deviceId == identity.deviceId {
            currentExerciseId = nil
            pendingFetchAvailable = false
            UserDefaults.standard.removeObject(forKey: Keys.exerciseId)
            UserDefaults.standard.removeObject(forKey: Keys.startedAt)
            UserDefaults.standard.removeObject(forKey: Keys.stoppedAt)
        }
        statusText = "Raw recording verified in AthleteOS. Local phone copy cleaned up."
    }

    func cleanupQueuedSensorCopies() async {
        guard !nightActionInProgress, connectionState == .connected,
              h10RecordingFeatureReady, fileTransferFeatureReady,
              !recordingOngoing, !pendingFetchAvailable,
              !fetchInProgress, !pftpOperationInProgress else { return }
        pftpOperationInProgress = true
        defer { pftpOperationInProgress = false }
        do {
            // Finishes any verified local deletion interrupted by an app restart.
            let jobs = try await store.readySensorCleanups()
            pendingSensorCleanupCount = jobs.count
            guard !jobs.isEmpty else { return }
            let status = try await requestStatusWithTimeout()
            guard !status.ongoing else { return }
            let entries = try await listExercisesWithTimeout(seconds: 12)
            for job in jobs where job.identity.deviceId == deviceId {
                if let entry = entries.first(where: { $0.entryId == job.identity.exerciseId }) {
                    let sensorAPI = api
                    let sensorId = deviceId
                    _ = try await boundedSensorOperation {
                        try await sensorAPI.removeExercise(sensorId, entry: entry)
                        return true
                    }
                }
                // A completed listing with no matching entry also confirms cleanup.
                try await store.finishSensorCleanup(job)
            }
            pendingSensorCleanupCount = try await store.readySensorCleanups().count
            statusText = pendingSensorCleanupCount == 0 ? "Night archived. H10 cleanup complete." : "Night archived. H10 cleanup will retry later."
        } catch {
            statusText = "Archived recordings are safe in AthleteOS. H10 cleanup will retry later."
        }
    }

    private func startResearchCapture(exerciseId: String, startedAt: Date) async {
        rawCaptureExpected = true
        UserDefaults.standard.set(true, forKey: Keys.rawCaptureExpected)

        // The H10 internal RR record is already confirmed before we reach this code.
        // Any failure below is therefore non-fatal to the safety/master recording.
        for _ in 0..<50 where !onlineStreamingFeatureReady {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }

        guard onlineStreamingFeatureReady else {
            rawStreamStatus = "RR only · PMD streaming service not ready"
            rawStreamActive = false
            return
        }

        do {
            let available = try await api.getAvailableOnlineStreamDataTypes(deviceId)
            var descriptors: [ResearchChannelDescriptor] = []
            var ecgSetting: PolarSensorSetting?
            var accSetting: PolarSensorSetting?

            if available.contains(.ecg) {
                let supported = try await api.requestStreamSettings(deviceId, feature: .ecg)
                let selected = supported.maxSettings()
                ecgSetting = selected
                descriptors.append(
                    channelDescriptor(
                        channel: "ecg",
                        source: "Polar H10 PMD",
                        unit: "microvolt",
                        encoding: "little_endian:uint64_timestamp_ns,int32_microvolts",
                        supported: supported,
                        selected: selected
                    )
                )
            }

            if available.contains(.acc) {
                let supported = try await api.requestStreamSettings(deviceId, feature: .acc)
                let selected = try conservativeAccelerometerSettings(from: supported)
                accSetting = selected
                descriptors.append(
                    channelDescriptor(
                        channel: "acc",
                        source: "Polar H10 PMD",
                        unit: "milli-g",
                        encoding: "little_endian:uint64_timestamp_ns,int32_x_mg,int32_y_mg,int32_z_mg",
                        supported: supported,
                        selected: selected
                    )
                )
            }

            if hrFeatureReady {
                descriptors.append(
                    ResearchChannelDescriptor(
                        channel: "hr",
                        source: "Bluetooth Heart Rate Service",
                        sampleRateHz: nil,
                        unit: "bpm + rr_ms",
                        recordEncoding: "ndjson:ResearchHRSample",
                        supportedSettings: [:],
                        selectedSettings: [:]
                    )
                )
            }

            guard !descriptors.isEmpty else {
                rawStreamStatus = "RR only · ECG/accelerometer not advertised"
                rawStreamActive = false
                return
            }

            if await researchStore.activeCaptureId() == nil {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
                let metadata = ResearchDeviceMetadata(
                    deviceId: deviceId,
                    model: "Polar H10",
                    firmwareVersion: firmwareVersion,
                    polarSdkVersion: PolarBleApiDefaultImpl.versionInfo(),
                    appVersion: version,
                    appBuild: build,
                    internalRRExerciseId: exerciseId,
                    batteryPercentAtStart: batteryPercent
                )
                _ = try await researchStore.begin(
                    metadata: metadata,
                    channels: descriptors,
                    startedAt: startedAt
                )
            } else {
                try? await researchStore.appendEvent(
                    kind: "gap_ended",
                    detail: "Bluetooth/PMD connection restored; raw streams restarting."
                )
            }

            startStreamTasks(ecgSetting: ecgSetting, accSetting: accSetting)
            await refreshRawCaptureSize()
        } catch {
            rawStreamActive = false
            rawStreamStatus = "RR safe · high-resolution start failed"
            try? await researchStore.appendEvent(
                kind: "stream_start_failed",
                detail: error.localizedDescription
            )
        }
    }

    private func resumeResearchStreamsAfterReconnect() async {
        guard rawCaptureExpected, recordingOngoing, !rawStreamActive,
              let exerciseId = currentExerciseId else { return }
        let startedAt = UserDefaults.standard.object(forKey: Keys.startedAt) as? Date ?? Date()
        await startResearchCapture(exerciseId: exerciseId, startedAt: startedAt)
    }

    private func recoverResearchAfterFeatureReadyIfNeeded() async {
        guard rawCaptureExpected,
              pendingFetchAvailable,
              !recordingOngoing,
              !didAutoRefreshCurrentConnection,
              !nightActionInProgress,
              !fetchInProgress,
              !pftpOperationInProgress,
              h10RecordingFeatureReady,
              fileTransferFeatureReady else { return }

        didAutoRefreshCurrentConnection = true
        pftpOperationInProgress = true
        defer { pftpOperationInProgress = false }

        do {
            let status = try await requestStatusWithTimeout()
            recordingOngoing = status.ongoing
            if status.ongoing {
                if !status.entryId.isEmpty {
                    currentExerciseId = status.entryId
                    UserDefaults.standard.set(status.entryId, forKey: Keys.exerciseId)
                }
                await resumeResearchStreamsAfterReconnect()
            } else {
                rawCaptureExpected = false
                UserDefaults.standard.set(false, forKey: Keys.rawCaptureExpected)
                rawStreamStatus = "Previous high-resolution capture ended unexpectedly; raw chunks retained"
            }
        } catch {
            didAutoRefreshCurrentConnection = false
            rawStreamStatus = "RR safety state retained; high-resolution recovery will retry"
        }
    }

    private func startStreamTasks(ecgSetting: PolarSensorSetting?, accSetting: PolarSensorSetting?) {
        ecgStreamTask?.cancel()
        accStreamTask?.cancel()
        hrStreamTask?.cancel()

        ecgStreamRunning = false
        accStreamRunning = false
        hrStreamRunning = false
        lastECGAnchorAt = nil
        lastACCAnchorAt = nil

        if let ecgSetting {
            ecgStreamRunning = true
            ecgStreamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await batch in self.api.startEcgStreaming(self.deviceId, settings: ecgSetting) {
                        if Task.isCancelled { break }
                        let receivedAt = Date()
                        let samples = batch.map {
                            ResearchECGSample(deviceTimestampNs: $0.timeStamp, voltageMicrovolts: $0.voltage)
                        }
                        try await self.researchStore.appendECG(samples)
                        if let first = samples.first,
                           self.lastECGAnchorAt.map({ receivedAt.timeIntervalSince($0) >= 60 }) ?? true {
                            try await self.researchStore.appendTimeAnchor(
                                channel: "ecg",
                                deviceTimestampNs: first.deviceTimestampNs,
                                hostReceivedAt: receivedAt
                            )
                            self.lastECGAnchorAt = receivedAt
                        }
                        await self.refreshRawCaptureSize()
                    }
                } catch {
                    await self.streamEnded(channel: "ECG", error: error)
                }
            }
        }

        if let accSetting {
            accStreamRunning = true
            accStreamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await batch in self.api.startAccStreaming(self.deviceId, settings: accSetting) {
                        if Task.isCancelled { break }
                        let receivedAt = Date()
                        let samples = batch.samples.map {
                            ResearchACCSample(
                                deviceTimestampNs: $0.timeStamp,
                                xMilliG: $0.x,
                                yMilliG: $0.y,
                                zMilliG: $0.z
                            )
                        }
                        try await self.researchStore.appendACC(samples)
                        if let first = samples.first,
                           self.lastACCAnchorAt.map({ receivedAt.timeIntervalSince($0) >= 60 }) ?? true {
                            try await self.researchStore.appendTimeAnchor(
                                channel: "acc",
                                deviceTimestampNs: first.deviceTimestampNs,
                                hostReceivedAt: receivedAt
                            )
                            self.lastACCAnchorAt = receivedAt
                        }
                        await self.refreshRawCaptureSize()
                    }
                } catch {
                    await self.streamEnded(channel: "accelerometer", error: error)
                }
            }
        }

        if hrFeatureReady {
            hrStreamRunning = true
            hrStreamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await batch in self.api.startHrStreaming(self.deviceId) {
                        if Task.isCancelled { break }
                        let receivedAt = Date()
                        let samples = batch.map {
                            ResearchHRSample(
                                receivedAt: receivedAt,
                                bpm: $0.hr,
                                rrMs: $0.rrsMs,
                                rrAvailable: $0.rrAvailable,
                                contactStatus: $0.contactStatus,
                                contactStatusSupported: $0.contactStatusSupported
                            )
                        }
                        try await self.researchStore.appendHR(samples)
                        await self.refreshRawCaptureSize()
                    }
                } catch {
                    await self.streamEnded(channel: "HR", error: error)
                }
            }
        }

        rawStreamActive = ecgStreamRunning || accStreamRunning || hrStreamRunning
        let channels = [
            ecgStreamRunning ? "ECG" : nil,
            accStreamRunning ? "ACC" : nil,
            hrStreamRunning ? "HR" : nil
        ].compactMap { $0 }
        rawStreamStatus = channels.isEmpty ? "RR only" : channels.joined(separator: " + ")
    }

    private func streamEnded(channel: String, error: Error) async {
        if Task.isCancelled { return }
        await noteResearchGapAndReconnect(
            detail: "\(channel) stream ended: \(error.localizedDescription)"
        )
    }

    private func stopResearchCapture(reason: String) async {
        let storedCaptureId = await researchStore.activeCaptureId()
        let hadCapture = rawCaptureExpected || rawStreamActive || storedCaptureId != nil
        rawCaptureExpected = false
        UserDefaults.standard.set(false, forKey: Keys.rawCaptureExpected)
        researchReconnectTask?.cancel()
        researchReconnectTask = nil

        ecgStreamTask?.cancel()
        accStreamTask?.cancel()
        hrStreamTask?.cancel()
        ecgStreamTask = nil
        accStreamTask = nil
        hrStreamTask = nil

        if connectionState == .connected {
            if ecgStreamRunning { try? await api.stopStreaming(deviceId, type: .ecg) }
            if accStreamRunning { try? await api.stopStreaming(deviceId, type: .acc) }
            if hrStreamRunning { try? await api.stopHrStreaming(deviceId) }
        }

        ecgStreamRunning = false
        accStreamRunning = false
        hrStreamRunning = false
        rawStreamActive = false

        if hadCapture {
            try? await researchStore.appendEvent(kind: "capture_stop_requested", detail: reason)
            if let summary = try? await researchStore.finish(
                state: .completed,
                batteryPercentAtEnd: batteryPercent
            ) {
                rawCaptureBytes = summary.totalBytes
            }
        }
        rawStreamStatus = "Stopped"
    }

    private func noteResearchGapAndReconnect(detail: String) async {
        guard rawCaptureExpected else { return }
        if researchReconnectTask != nil { return }
        ecgStreamTask?.cancel()
        accStreamTask?.cancel()
        hrStreamTask?.cancel()
        ecgStreamTask = nil
        accStreamTask = nil
        hrStreamTask = nil
        ecgStreamRunning = false
        accStreamRunning = false
        hrStreamRunning = false
        rawStreamActive = false
        rawStreamStatus = "RR safe · reconnecting high-resolution stream"
        try? await researchStore.appendEvent(kind: "gap_started", detail: detail)
        scheduleResearchReconnect()
    }

    private func scheduleResearchReconnect() {
        guard rawCaptureExpected, recordingOngoing, bluetoothOn else { return }
        guard researchReconnectTask == nil else { return }

        researchReconnectTask = Task { [weak self] in
            guard let self else { return }
            let delays: [UInt64] = [2, 5, 10, 20, 30]
            for delay in delays {
                if Task.isCancelled || !self.rawCaptureExpected || !self.recordingOngoing { break }
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }

                if self.connectionState == .connected {
                    if self.onlineStreamingFeatureReady {
                        await self.resumeResearchStreamsAfterReconnect()
                        if self.rawStreamActive { break }
                    }
                    continue
                }

                do {
                    try self.api.connectToDevice(self.deviceId)
                } catch {
                    try? await self.researchStore.appendEvent(
                        kind: "reconnect_failed",
                        detail: error.localizedDescription
                    )
                }
            }
            self.researchReconnectTask = nil
        }
    }

    private func refreshRawCaptureSize() async {
        if let summary = await researchStore.activeSummary() {
            rawCaptureBytes = summary.totalBytes
        }
    }

    private func channelDescriptor(
        channel: String,
        source: String,
        unit: String,
        encoding: String,
        supported: PolarSensorSetting,
        selected: PolarSensorSetting
    ) -> ResearchChannelDescriptor {
        let supportedMap = Dictionary(uniqueKeysWithValues: supported.settings.map {
            (settingName($0.key), Array($0.value).sorted())
        })
        var selectedMap: [String: UInt32] = [:]
        for (type, values) in selected.settings {
            if let value = values.first {
                selectedMap[settingName(type)] = value
            }
        }
        return ResearchChannelDescriptor(
            channel: channel,
            source: source,
            sampleRateHz: selected.settings[.sampleRate]?.first,
            unit: unit,
            recordEncoding: encoding,
            supportedSettings: supportedMap,
            selectedSettings: selectedMap
        )
    }

    private func conservativeAccelerometerSettings(from supported: PolarSensorSetting) throws -> PolarSensorSetting {
        var selected: [PolarSensorSetting.SettingType: UInt32] = [:]
        for (type, values) in supported.settings {
            guard !values.isEmpty else { continue }
            if type == .sampleRate {
                // 25 Hz is already sufficient for overnight movement/restlessness,
                // while materially reducing H10/iPhone battery and raw storage cost.
                selected[type] = values.contains(25) ? 25 : values.min()
            } else if type == .range || type == .rangeMilliunit {
                // Overnight body movement is low amplitude; choose the smallest
                // available accelerometer range for the highest useful resolution.
                selected[type] = values.min()
            } else {
                selected[type] = values.max()
            }
        }
        return try PolarSensorSetting(selected)
    }

    private func settingName(_ type: PolarSensorSetting.SettingType) -> String {
        switch type {
        case .sampleRate: return "sample_rate_hz"
        case .resolution: return "resolution_bits"
        case .range: return "range"
        case .rangeMilliunit: return "range_milliunit"
        case .channels: return "channels"
        case .unknown: return "unknown"
        }
    }

    private func requestStatusWithTimeout() async throws -> PolarRecordingStatus {
        let sensorAPI = api
        let sensorId = deviceId
        return try await boundedSensorOperation { try await sensorAPI.requestRecordingStatus(sensorId) }
    }

    private func boundedSensorOperation<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { [api, deviceId] in
                try await Task.sleep(for: .seconds(25))
                try? api.disconnectFromDevice(deviceId)
                throw NSError(domain: "AthleteOSRecorder", code: 1010, userInfo: [NSLocalizedDescriptionKey: "H10 operation timed out. Sensor data is retained; try again."])
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
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
            self.onlineStreamingFeatureReady = false
            self.hrFeatureReady = false
            self.didAutoRefreshCurrentConnection = false
            self.statusText = "Connecting to \(identifier.deviceId)…"
        }
    }

    nonisolated func deviceConnected(_ identifier: PolarDeviceInfo) {
        Task { @MainActor in
            self.stopScanning()
            self.deviceId = identifier.deviceId
            self.connectionState = .connected
            self.statusText = self.preparationMessage
            self.watchPreparation()
        }
    }

    nonisolated func deviceDisconnected(_ identifier: PolarDeviceInfo, info: PolarBleDisconnectInfo) {
        Task { @MainActor in
            self.preparationTask?.cancel()
            self.connectionState = .disconnected
            self.h10RecordingFeatureReady = false
            self.fileTransferFeatureReady = false
            self.onlineStreamingFeatureReady = false
            self.hrFeatureReady = false
            self.didAutoRefreshCurrentConnection = false
            if self.rawCaptureExpected && self.recordingOngoing {
                await self.noteResearchGapAndReconnect(detail: "Bluetooth disconnected")
            }
            if self.recordingOngoing {
                self.statusText = "Phone disconnected; H10 internal RR remains the source of truth."
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
            if self.rawCaptureExpected && self.recordingOngoing {
                self.scheduleResearchReconnect()
            }
        }
    }

    nonisolated func blePowerOff() {
        Task { @MainActor in
            self.stopScanning()
            self.bluetoothOn = false
            self.preparationTask?.cancel()
            self.connectionState = .disconnected
            self.h10RecordingFeatureReady = false
            self.fileTransferFeatureReady = false
            self.onlineStreamingFeatureReady = false
            self.hrFeatureReady = false
            if self.rawCaptureExpected && self.recordingOngoing {
                try? await self.researchStore.appendEvent(kind: "gap_started", detail: "Bluetooth powered off.")
            }
            self.statusText = "Bluetooth is off. H10 internal RR continues independently."
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
            case .feature_polar_online_streaming:
                self.onlineStreamingFeatureReady = true
            case .feature_hr:
                self.hrFeatureReady = true
            default:
                break
            }

            if self.rawCaptureExpected,
               self.recordingOngoing,
               self.connectionState == .connected,
               self.onlineStreamingFeatureReady,
               !self.rawStreamActive {
                Task { await self.resumeResearchStreamsAfterReconnect() }
            }

            guard
                self.connectionState == .connected,
                self.h10RecordingFeatureReady,
                self.fileTransferFeatureReady
            else {
                return
            }

            if self.rawCaptureExpected,
               self.pendingFetchAvailable,
               !self.recordingOngoing {
                Task { await self.recoverResearchAfterFeatureReadyIfNeeded() }
            }

            self.preparationTask?.cancel()
            self.preparationTimedOut = false
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
