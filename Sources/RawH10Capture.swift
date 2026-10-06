import Foundation
import CoreBluetooth
import PolarBleSdk
import UIKit

@MainActor
final class RawH10Capture: NSObject, ObservableObject {
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

    @Published private(set) var bluetoothOn = false
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var scanning = false
    @Published private(set) var nearbyH10s: [NearbyH10] = []
    @Published private(set) var deviceId: String
    @Published private(set) var deviceName = "Polar H10"
    @Published private(set) var batteryPercent: UInt?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var streamingReady = false
    @Published private(set) var hrReady = false

    @Published private(set) var captureRequested = false
    @Published private(set) var capturing = false
    @Published private(set) var captureStartedAt: Date?
    @Published private(set) var currentCaptureId: UUID?
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var ecgSamples: UInt64 = 0
    @Published private(set) var accSamples: UInt64 = 0
    @Published private(set) var hrRecords: UInt64 = 0
    @Published private(set) var statusText = "Ready"
    @Published private(set) var lastError: String?

    private let store = ResearchCaptureStore.shared
    private var scanTask: Task<Void, Never>?
    private var ecgTask: Task<Void, Never>?
    private var accTask: Task<Void, Never>?
    private var hrTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectGeneration: UInt64 = 0
    private var stopping = false
    private var startWhenReady = false

    private lazy var api: PolarBleApi = {
        let api = PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue.main,
            features: [
                .feature_battery_info,
                .feature_device_info,
                .feature_hr,
                .feature_polar_online_streaming
            ],
            restoreIdentifier: "nz.co.athleteos.recorder.raw"
        )
        api.automaticReconnection = true
        return api
    }()

    private enum Keys {
        static let deviceId = "raw.deviceId"
        static let activeCaptureId = "raw.activeCaptureId"
        static let captureStartedAt = "raw.captureStartedAt"
    }

    override init() {
        self.deviceId = UserDefaults.standard.string(forKey: Keys.deviceId) ?? ""
        if let raw = UserDefaults.standard.string(forKey: Keys.activeCaptureId),
           let id = UUID(uuidString: raw) {
            self.currentCaptureId = id
            self.captureRequested = true
            self.captureStartedAt = UserDefaults.standard.object(forKey: Keys.captureStartedAt) as? Date
            self.statusText = "Reconnecting to continue raw capture…"
        }
        super.init()

        api.observer = self
        api.powerStateObserver = self
        api.deviceFeaturesObserver = self
        api.deviceInfoObserver = self
        api.polarFilter(true)
        bluetoothOn = api.isBlePowered

        if !deviceId.isEmpty && captureRequested && bluetoothOn {
            connect()
        }
    }

    deinit {
        scanTask?.cancel()
        ecgTask?.cancel()
        accTask?.cancel()
        hrTask?.cancel()
        startTask?.cancel()
        reconnectTask?.cancel()
    }

    var readyToStart: Bool {
        bluetoothOn && connectionState == .connected && streamingReady && hrReady
    }

    var primaryButtonTitle: String {
        if captureRequested { return capturing ? "STOP RECORDING" : "STOP" }
        if deviceId.isEmpty { return scanning ? "SEARCHING…" : "FIND H10" }
        if connectionState == .disconnected { return "CONNECT H10" }
        if connectionState == .connecting || !readyToStart { return "PREPARING…" }
        return "START RECORDING"
    }

    func primaryAction() {
        if captureRequested {
            Task { await stopCapture() }
            return
        }
        if deviceId.isEmpty {
            startScanning()
            return
        }
        if connectionState == .disconnected {
            startWhenReady = true
            connect()
            return
        }
        guard readyToStart else {
            startWhenReady = true
            statusText = "Preparing raw-data streams…"
            return
        }
        startWhenReady = false
        Task { await startCapture() }
    }

    func startScanning() {
        clearError()
        guard bluetoothOn else {
            fail("Turn Bluetooth on, then try again.")
            return
        }
        guard !captureRequested else { return }

        stopScanning()
        nearbyH10s = []
        scanning = true
        statusText = "Looking for your H10…"

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await device in self.api.searchForDevice(withNameContaining: "Polar") {
                    if Task.isCancelled { break }
                    let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard device.connectable, name.uppercased().contains("H10") else { continue }
                    let found = NearbyH10(id: device.deviceId, name: name, rssi: device.rssi)
                    if let index = self.nearbyH10s.firstIndex(where: { $0.id == found.id }) {
                        self.nearbyH10s[index] = found
                    } else {
                        self.nearbyH10s.append(found)
                    }
                    self.nearbyH10s.sort { $0.rssi > $1.rssi }
                    self.statusText = "Tap your H10 once."
                }
            } catch {
                if !Task.isCancelled { self.fail("H10 search failed: \(error.localizedDescription)") }
            }
            if !Task.isCancelled {
                self.scanning = false
                if self.nearbyH10s.isEmpty && self.lastError == nil {
                    self.statusText = "No H10 found. Wet the strap, put it on, then try again."
                }
            }
        }
    }

    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }

    func select(_ h10: NearbyH10) {
        guard !captureRequested else { return }
        stopScanning()
        deviceId = h10.id
        deviceName = h10.name
        UserDefaults.standard.set(deviceId, forKey: Keys.deviceId)
        startWhenReady = true
        connect()
    }

    func forgetSensor() {
        guard !captureRequested else { return }
        disconnect()
        deviceId = ""
        deviceName = "Polar H10"
        nearbyH10s = []
        UserDefaults.standard.removeObject(forKey: Keys.deviceId)
        statusText = "Ready to find an H10."
    }

    func connect() {
        clearError()
        guard bluetoothOn else {
            fail("Turn Bluetooth on, then try again.")
            return
        }
        guard !deviceId.isEmpty else {
            startScanning()
            return
        }
        streamingReady = false
        hrReady = false
        connectionState = .connecting
        statusText = captureRequested ? "Reconnecting raw capture…" : "Connecting H10…"
        do {
            try api.connectToDevice(deviceId)
        } catch {
            connectionState = .disconnected
            fail("Could not connect to H10: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        guard !captureRequested, !deviceId.isEmpty else { return }
        do {
            try api.disconnectFromDevice(deviceId)
        } catch {
            fail("Could not disconnect: \(error.localizedDescription)")
        }
    }

    func startCapture() async {
        guard !captureRequested, readyToStart else { return }
        clearError()
        captureRequested = true
        capturing = false
        ecgSamples = 0
        accSamples = 0
        hrRecords = 0
        let startedAt = Date()
        captureStartedAt = startedAt
        UserDefaults.standard.set(startedAt, forKey: Keys.captureStartedAt)
        statusText = "Starting raw ECG, movement and RR capture…"

        do {
            try await prepareAndStartNewCapture()
        } catch {
            captureRequested = false
            capturing = false
            captureStartedAt = nil
            currentCaptureId = nil
            UserDefaults.standard.removeObject(forKey: Keys.activeCaptureId)
            UserDefaults.standard.removeObject(forKey: Keys.captureStartedAt)
            fail("Could not start raw capture: \(friendly(error))")
        }
    }

    func stopCapture() async {
        guard captureRequested else { return }
        stopping = true
        defer { stopping = false }
        statusText = "Stopping raw capture…"
        captureRequested = false

        stopStreamTasks()
        reconnectTask?.cancel()
        reconnectTask = nil

        do {
            if let summary = try await store.snapshot() {
                _ = try await store.finish(
                    h10BatteryEndPercent: batteryPercent,
                    phoneBatteryEndPercent: phoneBatteryPercent()
                )
                lastCaptureURL = summary.directory
            } else if let id = currentCaptureId {
                let summary = try await store.summary(captureId: id)
                lastCaptureURL = summary.directory
            }
            capturing = false
            currentCaptureId = nil
            captureStartedAt = nil
            UserDefaults.standard.removeObject(forKey: Keys.activeCaptureId)
            UserDefaults.standard.removeObject(forKey: Keys.captureStartedAt)
            statusText = "Raw data saved."
        } catch {
            capturing = false
            fail("Capture stopped, but final save needs attention: \(friendly(error))")
        }
    }

    private func prepareAndStartNewCapture() async throws {
        let ecgAvailable = try await api.requestStreamSettings(deviceId, feature: .ecg)
        let accAvailable = try await api.requestStreamSettings(deviceId, feature: .acc)
        let ecgSelected = ecgAvailable.maxSettings()
        let accSelected = accAvailable.maxSettings()

        let configuration = ResearchCaptureConfiguration(
            ecg: researchSettings(available: ecgAvailable, selected: ecgSelected),
            accelerometer: researchSettings(available: accAvailable, selected: accSelected),
            hrServiceEnabled: true,
            sensorTimestampEpoch: "2000-01-01T00:00:00",
            sensorTimestampUnit: "nanoseconds"
        )

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let summary = try await store.start(
            deviceId: deviceId,
            deviceModel: deviceName,
            firmwareVersion: firmwareVersion,
            polarSdkVersion: PolarBleApiDefaultImpl.versionInfo(),
            appVersion: appVersion,
            appBuild: appBuild,
            safetyExerciseId: "not-used",
            configuration: configuration,
            h10BatteryStartPercent: batteryPercent,
            phoneBatteryStartPercent: phoneBatteryPercent()
        )

        currentCaptureId = summary.captureId
        UserDefaults.standard.set(summary.captureId.uuidString, forKey: Keys.activeCaptureId)
        try await store.recordEvent(
            kind: "stream_configuration",
            details: [
                "ecg": settingsDescription(ecgSelected),
                "acc": settingsDescription(accSelected)
            ]
        )
        startStreams(ecgSettings: ecgSelected, accSettings: accSelected)
        capturing = true
        statusText = "Recording raw H10 data."
    }

    private func resumeCaptureIfNeeded() async {
        guard captureRequested, !capturing, readyToStart, let id = currentCaptureId else { return }
        clearError()
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ecgAvailable = try await self.api.requestStreamSettings(self.deviceId, feature: .ecg)
                let accAvailable = try await self.api.requestStreamSettings(self.deviceId, feature: .acc)
                let ecgSelected = ecgAvailable.maxSettings()
                let accSelected = accAvailable.maxSettings()

                if try await self.store.snapshot() == nil {
                    _ = try await self.store.resume(captureId: id, reason: "app or Bluetooth reconnection")
                } else {
                    try await self.store.recordEvent(kind: "ble_reconnected", reason: "stream restart")
                }
                self.startStreams(ecgSettings: ecgSelected, accSettings: accSelected)
                self.capturing = true
                self.statusText = "Recording raw H10 data."
            } catch {
                self.capturing = false
                self.fail("Raw capture could not resume: \(self.friendly(error))")
                self.scheduleReconnect()
            }
        }
    }

    private func startStreams(ecgSettings: PolarSensorSetting, accSettings: PolarSensorSetting) {
        stopStreamTasks()
        let id = deviceId

        ecgTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await packet in self.api.startEcgStreaming(id, settings: ecgSettings) {
                    if Task.isCancelled || !self.captureRequested { break }
                    let samples = packet.map { ResearchECGSample(sensorTimestampNs: $0.timeStamp, microvolts: $0.voltage) }
                    try await self.store.appendECG(samples)
                    self.ecgSamples &+= UInt64(samples.count)
                }
            } catch {
                await self.streamFailed(channel: "ecg", error: error)
            }
        }

        accTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await packet in self.api.startAccStreaming(id, settings: accSettings) {
                    if Task.isCancelled || !self.captureRequested { break }
                    let samples = packet.map {
                        ResearchACCSample(
                            sensorTimestampNs: $0.timeStamp,
                            xMilliG: $0.x,
                            yMilliG: $0.y,
                            zMilliG: $0.z
                        )
                    }
                    try await self.store.appendACC(samples)
                    self.accSamples &+= UInt64(samples.count)
                }
            } catch {
                await self.streamFailed(channel: "acc", error: error)
            }
        }

        hrTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await packet in self.api.startHrStreaming(id) {
                    if Task.isCancelled || !self.captureRequested { break }
                    let received = Date()
                    let samples = packet.map {
                        ResearchHRSample(
                            receivedAt: received,
                            heartRateBpm: $0.hr,
                            rrIntervalsMs: $0.rrsMs,
                            rrAvailable: $0.rrAvailable,
                            contactStatus: $0.contactStatus,
                            contactStatusSupported: $0.contactStatusSupported
                        )
                    }
                    try await self.store.appendHR(samples)
                    self.hrRecords &+= UInt64(samples.count)
                }
            } catch {
                await self.streamFailed(channel: "hr", error: error)
            }
        }
    }

    private func stopStreamTasks() {
        ecgTask?.cancel()
        accTask?.cancel()
        hrTask?.cancel()
        ecgTask = nil
        accTask = nil
        hrTask = nil
    }

    private func streamFailed(channel: String, error: Error) async {
        guard captureRequested, !stopping else { return }
        capturing = false
        try? await store.recordEvent(
            kind: "stream_error",
            channel: channel,
            reason: friendly(error)
        )
        statusText = "Signal interrupted. Reconnecting automatically…"
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard captureRequested, !deviceId.isEmpty else { return }
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<6 {
                if Task.isCancelled || !self.captureRequested || generation != self.reconnectGeneration { return }
                let delay = min(2 << attempt, 30)
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if self.connectionState == .disconnected {
                    self.connect()
                }
                for _ in 0..<100 {
                    if Task.isCancelled || !self.captureRequested { return }
                    if self.readyToStart {
                        await self.resumeCaptureIfNeeded()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            self.fail("H10 is still disconnected. Keep the phone nearby and reopen Recorder; the raw file already collected is retained.")
        }
    }

    private func researchSettings(available: PolarSensorSetting, selected: PolarSensorSetting) -> ResearchStreamSettings {
        let availableRates = available.settings[.sampleRate]?.map(Int.init).sorted() ?? []
        let availableResolution = available.settings[.resolution]?.map(Int.init).sorted() ?? []
        let availableRanges = available.settings[.range]?.map(Int.init).sorted() ?? []
        return ResearchStreamSettings(
            selectedSampleRateHz: Int(selected.settings[.sampleRate]?.first ?? 0),
            selectedResolutionBits: selected.settings[.resolution]?.first.map(Int.init),
            selectedRange: selected.settings[.range]?.first.map(Int.init),
            supportedSampleRatesHz: availableRates,
            supportedResolutionBits: availableResolution,
            supportedRanges: availableRanges
        )
    }

    private func settingsDescription(_ settings: PolarSensorSetting) -> String {
        settings.settings
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value.sorted())" }
            .joined(separator: ",")
    }

    private func phoneBatteryPercent() -> Int? {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
        #else
        return nil
        #endif
    }

    private func clearError() {
        lastError = nil
    }

    private func fail(_ message: String) {
        lastError = message
        statusText = message
    }

    private func friendly(_ error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(describing: error) : text
    }
}

extension RawH10Capture: PolarBleApiObserver {
    nonisolated func deviceConnecting(_ identifier: PolarDeviceInfo) {
        Task { @MainActor in
            self.deviceName = identifier.name.isEmpty ? "Polar H10" : identifier.name
            self.connectionState = .connecting
            self.statusText = self.captureRequested ? "Reconnecting raw capture…" : "Connecting H10…"
        }
    }

    nonisolated func deviceConnected(_ identifier: PolarDeviceInfo) {
        Task { @MainActor in
            self.stopScanning()
            self.deviceId = identifier.deviceId
            self.deviceName = identifier.name.isEmpty ? "Polar H10" : identifier.name
            UserDefaults.standard.set(identifier.deviceId, forKey: Keys.deviceId)
            self.connectionState = .connected
            self.streamingReady = false
            self.hrReady = false
            self.statusText = self.captureRequested ? "Restoring raw-data streams…" : "Preparing raw-data streams…"
        }
    }

    nonisolated func deviceDisconnected(_ identifier: PolarDeviceInfo, info: PolarBleDisconnectInfo) {
        Task { @MainActor in
            self.connectionState = .disconnected
            self.streamingReady = false
            self.hrReady = false
            self.stopStreamTasks()
            if self.captureRequested && !self.stopping {
                self.capturing = false
                try? await self.store.recordEvent(kind: "ble_disconnected", reason: "connection lost")
                self.statusText = "Signal interrupted. Reconnecting automatically…"
                self.scheduleReconnect()
            } else {
                self.statusText = "Disconnected."
            }
        }
    }
}

extension RawH10Capture: PolarBleApiPowerStateObserver {
    nonisolated func blePowerOn() {
        Task { @MainActor in
            self.bluetoothOn = true
            if self.captureRequested && self.connectionState == .disconnected {
                self.scheduleReconnect()
            }
        }
    }

    nonisolated func blePowerOff() {
        Task { @MainActor in
            self.bluetoothOn = false
            self.connectionState = .disconnected
            self.streamingReady = false
            self.hrReady = false
            self.capturing = false
            if self.captureRequested {
                try? await self.store.recordEvent(kind: "bluetooth_off", reason: "Bluetooth powered off")
                self.statusText = "Bluetooth is off. Raw data already saved is retained."
            } else {
                self.statusText = "Bluetooth is off."
            }
        }
    }
}

extension RawH10Capture: PolarBleApiDeviceFeaturesObserver {
    nonisolated func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        Task { @MainActor in
            switch feature {
            case .feature_polar_online_streaming:
                self.streamingReady = true
            case .feature_hr:
                self.hrReady = true
            default:
                break
            }

            if self.readyToStart {
                if self.captureRequested {
                    await self.resumeCaptureIfNeeded()
                } else if self.startWhenReady {
                    self.startWhenReady = false
                    await self.startCapture()
                } else {
                    self.statusText = "Ready to record raw H10 data."
                }
            }
        }
    }
}

extension RawH10Capture: PolarBleApiDeviceInfoObserver {
    nonisolated func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        Task { @MainActor in self.batteryPercent = batteryLevel }
    }

    nonisolated func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {}

    nonisolated func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        guard uuid == CBUUID(string: "2A26") else { return }
        Task { @MainActor in self.firmwareVersion = value.replacingOccurrences(of: "\u{0000}", with: "") }
    }

    nonisolated func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        guard key.uppercased() == "2A26" || key.uppercased().contains("FIRMWARE") else { return }
        Task { @MainActor in self.firmwareVersion = value.replacingOccurrences(of: "\u{0000}", with: "") }
    }
}
