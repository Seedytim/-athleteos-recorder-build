import SwiftUI

private enum RecorderTheme {
    static let background = Color(red: 0.025, green: 0.035, blue: 0.035)
    static let card = Color(red: 0.065, green: 0.085, blue: 0.085)
    static let mint = Color(red: 0.31, green: 0.94, blue: 0.68)
    static let secondary = Color(red: 0.65, green: 0.71, blue: 0.70)
}

struct ContentView: View {
    @EnvironmentObject private var recorder: PolarH10Recorder
    @EnvironmentObject private var uploader: AthleteOSUploader
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSetup = false
    @State private var uploadPassInProgress = false

    private var sensorBusy: Bool {
        recorder.nightActionInProgress ||
        recorder.fetchInProgress ||
        recorder.pftpOperationInProgress ||
        recorder.recoveringConnection
    }

    private var busy: Bool { sensorBusy || uploader.busy }
    private var isNightOpen: Bool { recorder.recordingOngoing || recorder.pendingFetchAvailable }

    private var headline: String {
        if recorder.fetchInProgress { return "Saving raw data" }
        if recorder.nightActionInProgress { return isNightOpen ? "Ending recording" : "Starting recording" }
        if uploader.busy { return "Archiving raw RR" }
        if recorder.recordingOngoing {
            return recorder.rawStreamActive ? "Recording raw data" : "Recording RR safely"
        }
        if recorder.pendingFetchAvailable { return "Raw recording waiting" }
        if recorder.connectionState == .connecting { return "Connecting H10" }
        if recorder.connectionState == .connected && recorder.h10RecordingFeatureReady && recorder.fileTransferFeatureReady {
            return "Ready"
        }
        if recorder.deviceId.isEmpty { return "Set up your H10" }
        return "H10 disconnected"
    }

    private var detail: String {
        if recorder.recordingOngoing {
            return recorder.rawStreamStatus
        }
        if recorder.lastSavedFile != nil {
            return uploader.isConnected
                ? "Raw RR is saved on this iPhone and will archive automatically."
                : "Raw RR is saved on this iPhone. Connect AthleteOS once to archive automatically."
        }
        if recorder.pendingFetchAvailable {
            return "Tap End recording. The H10 copy stays untouched until the iPhone save and AthleteOS archive are verified."
        }
        if recorder.connectionState == .connected {
            return "One button records raw RR on the H10 and attempts ECG + accelerometer on the iPhone."
        }
        return "Wear the moistened Polar H10 strap, then connect."
    }

    private var buttonTitle: String {
        if recorder.fetchInProgress || recorder.nightActionInProgress {
            return isNightOpen ? "Ending…" : "Starting…"
        }
        if isNightOpen { return "End recording" }
        if recorder.deviceId.isEmpty { return "Set up H10" }
        return "Start recording"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AthleteOS")
                            .font(.headline)
                        Text("Recorder")
                            .font(.title2.weight(.bold))
                    }
                    Spacer()
                    Button { showSetup = true } label: {
                        Image(systemName: "gearshape")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Recorder setup")
                }

                Spacer(minLength: 12)

                ZStack {
                    Circle()
                        .fill((recorder.recordingOngoing ? RecorderTheme.mint : Color.white.opacity(0.08)))
                        .frame(width: 150, height: 150)
                    Image(systemName: recorder.recordingOngoing ? "waveform.path.ecg" : "heart.text.square")
                        .font(.system(size: 58, weight: .medium))
                        .foregroundStyle(recorder.recordingOngoing ? Color.black : Color.white)
                }

                VStack(spacing: 10) {
                    Text(headline)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(RecorderTheme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if recorder.recordingOngoing || recorder.rawStreamActive {
                    rawStatusCard
                }

                Button {
                    primaryAction()
                } label: {
                    HStack(spacing: 10) {
                        if busy || recorder.connectionState == .connecting {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: isNightOpen ? "stop.fill" : "record.circle")
                        }
                        Text(buttonTitle).font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 62)
                }
                .buttonStyle(RecorderPrimaryButton())
                .disabled(sensorBusy || !recorder.bluetoothOn)

                if recorder.scanning || !recorder.nearbyH10s.isEmpty {
                    nearbySensors
                }

                if let error = recorder.lastError {
                    notice(error)
                } else if let error = uploader.lastError {
                    notice(error)
                }

                Spacer()

                Text("Raw data only · no sleep staging or recovery scoring in Recorder")
                    .font(.caption)
                    .foregroundStyle(RecorderTheme.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(RecorderTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSetup) { setup }
            .onOpenURL { url in
                Task { _ = await uploader.handleConnectionURL(url) }
            }
            .task {
                await recorder.prepareRawCaptureRecovery()
                while !Task.isCancelled {
                    if scenePhase == .active {
                        await processPendingUploads()
                        await recorder.cleanupQueuedSensorCopies()
                    }
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { break }
                }
            }
            .onChange(of: recorder.lastSavedFile) { _ in
                Task { await processPendingUploads() }
            }
            .onChange(of: uploader.isConnected) { connected in
                if connected { Task { await processPendingUploads() } }
            }
            .onChange(of: recorder.connectionState) { state in
                if state == .connected {
                    Task { await recorder.cleanupQueuedSensorCopies() }
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await processPendingUploads()
                        await recorder.cleanupQueuedSensorCopies()
                    }
                }
            }
        }
        .tint(RecorderTheme.mint)
        .preferredColorScheme(.dark)
    }

    private var rawStatusCard: some View {
        VStack(spacing: 11) {
            statusLine("H10 raw RR", state: recorder.recordingOngoing ? "safe/master" : "stopped",
                       good: recorder.recordingOngoing)
            statusLine("ECG + accelerometer", state: recorder.rawStreamStatus,
                       good: recorder.rawStreamActive)
            if recorder.rawCaptureBytes > 0 {
                statusLine("Saved on iPhone", state: ByteCountFormatter.string(fromByteCount: Int64(recorder.rawCaptureBytes), countStyle: .file),
                           good: true)
            }
        }
        .padding(16)
        .background(RecorderTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func statusLine(_ title: String, state: String, good: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(good ? RecorderTheme.mint : Color.orange).frame(width: 8, height: 8)
            Text(title).font(.subheadline)
            Spacer()
            Text(state).font(.caption).foregroundStyle(RecorderTheme.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var nearbySensors: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recorder.scanning {
                HStack { ProgressView(); Text("Looking for H10…").font(.subheadline) }
            }
            ForEach(recorder.nearbyH10s) { h10 in
                Button {
                    recorder.connect(to: h10)
                } label: {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward")
                        VStack(alignment: .leading) {
                            Text(h10.name.isEmpty ? "Polar H10" : h10.name)
                            Text(h10.id).font(.caption).foregroundStyle(RecorderTheme.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(14)
                    .background(RecorderTheme.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RecorderTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func primaryAction() {
        if recorder.deviceId.isEmpty {
            showSetup = true
            recorder.startScanning()
            return
        }
        Task {
            await recorder.performNightAction()
            await processPendingUploads()
            await recorder.cleanupQueuedSensorCopies()
        }
    }

    private func upload(_ file: URL) async {
        let store = RecordingStore.shared
        guard let receipt = await uploader.upload(fileURL: file) else { return }
        do {
            let identity = try await store.confirmArchive(file, receipt: receipt)
            recorder.markArchiveConfirmedAndLocalDeleted(for: file, identity: identity)
            await recorder.cleanupQueuedSensorCopies()
        } catch {
            uploader.reportLocalCleanupError(error)
        }
    }

    private func processPendingUploads() async {
        guard !uploader.busy, !uploadPassInProgress else { return }
        uploadPassInProgress = true
        defer { uploadPassInProgress = false }

        await recorder.reconcileArchivedNight()
        guard uploader.isConnected else { return }

        do {
            let files = try await RecordingStore.shared.list()
            for file in files.reversed() {
                if Task.isCancelled || !uploader.isConnected { break }
                await upload(file.url)
            }
        } catch {
            uploader.reportLocalCleanupError(error)
        }
    }

    private var setup: some View {
        NavigationStack {
            Form {
                Section("Polar H10") {
                    LabeledContent("Bluetooth", value: recorder.bluetoothOn ? "On" : "Off")
                    LabeledContent("H10", value: recorder.connectionState.rawValue)
                    if let battery = recorder.batteryPercent {
                        LabeledContent("Battery", value: "\(battery)%")
                    }
                    if let firmware = recorder.firmwareVersion {
                        LabeledContent("Firmware", value: firmware)
                    }

                    if recorder.connectionState == .disconnected {
                        Button(recorder.scanning ? "Stop searching" : "Find nearby H10") {
                            if recorder.scanning { recorder.stopScanning() }
                            else { recorder.startScanning() }
                        }
                        .disabled(!recorder.bluetoothOn || sensorBusy)

                        if !recorder.deviceId.isEmpty {
                            Button("Reconnect saved H10") { recorder.connect() }
                                .disabled(sensorBusy)
                        }
                    } else {
                        Button("Disconnect H10") { recorder.disconnect() }
                            .disabled(sensorBusy)
                    }

                    ForEach(recorder.nearbyH10s) { h10 in
                        Button(h10.name.isEmpty ? h10.id : h10.name) {
                            recorder.connect(to: h10)
                        }
                    }
                }

                Section("AthleteOS raw archive") {
                    LabeledContent("Archive", value: uploader.isConnected ? "Connected" : "Not connected")
                    if uploader.isConnected {
                        Button("Disconnect AthleteOS", role: .destructive) { uploader.disconnect() }
                            .disabled(uploader.busy)
                    } else {
                        Link("Open AthleteOS", destination: URL(string: "https://athleteos-pink-sigma.vercel.app/")!)
                        SecureField("Connection key", text: $uploader.connectionKeyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Connect") { Task { await uploader.connect() } }
                            .disabled(uploader.busy || uploader.connectionKeyDraft.isEmpty)
                    }
                    Text("Recorder archives the raw H10 RR file automatically. It does not perform coaching, sleep staging, or recovery analysis.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Raw capture") {
                    LabeledContent("H10 RR", value: recorder.recordingOngoing ? "Recording" : "Idle")
                    LabeledContent("High-resolution", value: recorder.rawStreamStatus)
                    if recorder.rawCaptureBytes > 0 {
                        LabeledContent("Local raw size", value: ByteCountFormatter.string(fromByteCount: Int64(recorder.rawCaptureBytes), countStyle: .file))
                    }
                    if let id = recorder.currentExerciseId {
                        LabeledContent("Recording ID", value: id).font(.caption)
                    }
                    Text("ECG/accelerometer failure never stops or deletes the H10 internal RR safety recording.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSetup = false }
                }
            }
        }
        .tint(RecorderTheme.mint)
        .preferredColorScheme(.dark)
    }
}

private struct RecorderPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(
                RecorderTheme.mint,
                in: RoundedRectangle(cornerRadius: 18)
            )
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
