import SwiftUI

private enum Midnight {
    static let background = Color(red: 0.025, green: 0.035, blue: 0.035)
    static let card = Color(red: 0.065, green: 0.085, blue: 0.085)
    static let mint = Color(red: 0.31, green: 0.94, blue: 0.68)
    static let secondary = Color(red: 0.65, green: 0.71, blue: 0.70)
}

struct ContentView: View {
    @EnvironmentObject private var recorder: PolarH10Recorder
    @EnvironmentObject private var uploader: AthleteOSUploader
    @State private var showSettings = false
    @State private var showRecordings = false
    @State private var confirmDelete = false

    private var sensorBusy: Bool { recorder.fetchInProgress || recorder.pftpOperationInProgress }
    private var busy: Bool { sensorBusy || uploader.busy }
    private var ready: Bool { recorder.h10RecordingFeatureReady && recorder.fileTransferFeatureReady }
    private var uploaded: Bool {
        guard let file = recorder.lastSavedFile else { return false }
        return recorder.athleteOSUploadConfirmed || uploader.isUploaded(file)
    }
    private var title: String {
        if recorder.fetchInProgress { return "Saving your recording" }
        if uploader.busy { return uploader.isConnected ? "Uploading your recording" : "Connecting to AthleteOS" }
        if sensorBusy { return "Talking to your H10" }
        if recorder.recordingOngoing { return "Recording on H10" }
        if recorder.lastSavedFile != nil { return uploaded ? "Recording saved" : "Ready to upload" }
        if recorder.pendingFetchAvailable { return "Recording on your H10" }
        if recorder.connectionState == .connecting { return "Connecting your H10" }
        return ready ? "Ready to record" : "Let’s get connected"
    }
    private var subtitle: String {
        if recorder.fetchInProgress { return "Keep your H10 nearby while the raw recording is saved to your phone." }
        if uploader.busy { return uploader.statusText }
        if sensorBusy { return recorder.statusText }
        if recorder.recordingOngoing { return "Your sensor is recording independently. Reconnect when you’re ready to finish." }
        if recorder.lastSavedFile != nil { return uploaded ? "Your raw recording is on this phone and confirmed in AthleteOS." : "Your file is safe on this phone. Upload it to complete the transfer." }
        if recorder.pendingFetchAvailable { return "Reconnect to check or finish the recording and save it to your phone." }
        return ready ? "Your Polar H10 is ready to record RR intervals." : "Wear your H10 with the strap moistened, then connect to begin."
    }
    private var actionTitle: String {
        if recorder.fetchInProgress { return "Reading H10…" }
        if uploader.busy { return "Please wait…" }
        if sensorBusy { return "Working…" }
        if let _ = recorder.lastSavedFile, !uploaded { return uploader.isConnected ? "Upload recording" : "Connect AthleteOS" }
        if recorder.connectionState == .connecting { return "Connecting…" }
        if recorder.connectionState == .disconnected { return recorder.scanning ? "Stop searching" : recorder.deviceId.isEmpty ? "Find my H10" : "Reconnect H10" }
        if !ready { return "Preparing H10…" }
        if recorder.recordingOngoing || recorder.pendingFetchAvailable { return "Stop & save recording" }
        return "Start recording"
    }
    private var actionIcon: String {
        if recorder.lastSavedFile != nil && !uploaded { return "icloud.and.arrow.up" }
        if recorder.connectionState != .connected { return "antenna.radiowaves.left.and.right" }
        return recorder.recordingOngoing || recorder.pendingFetchAvailable ? "stop.fill" : "play.fill"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    sensorCard
                    hero
                    Button(action: primaryAction) {
                        HStack(spacing: 12) {
                            if busy || recorder.connectionState == .connecting { ProgressView().tint(.black) }
                            else { Image(systemName: actionIcon) }
                            Text(actionTitle).font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(MidnightPrimaryButton())
                    .disabled(busy || recorder.connectionState == .connecting || (!recorder.bluetoothOn && recorder.lastSavedFile == nil) || (recorder.connectionState == .connected && !ready && (recorder.lastSavedFile == nil || uploaded)))
                    nearbySensors
                    if let error = recorder.lastError { notice(error, icon: "exclamationmark.triangle", color: .orange) }
                    if let error = uploader.lastError { notice(error, icon: "icloud.slash", color: .orange) }
                    VStack(spacing: 12) {
                        Button { showRecordings = true } label: {
                            row(icon: "list.bullet.rectangle", title: "Saved recordings", subtitle: "View files and upload status")
                        }.buttonStyle(.plain)
                        Button { showSettings = true } label: {
                            row(icon: uploaded ? "checkmark.icloud" : "icloud", title: uploaded ? "Uploaded to AthleteOS" : "AthleteOS", subtitle: uploader.isConnected ? "Connected · automatic upload after saving" : "Connect once to upload your recordings")
                        }.buttonStyle(.plain)
                    }
                    Label("Saved on your phone before upload", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(Midnight.secondary)
                        .frame(maxWidth: .infinity).padding(.bottom, 14)
                }
                .padding(22).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Midnight.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { settings }
            .sheet(isPresented: $showRecordings) { recordings }
        }
        .tint(Midnight.mint).preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ATHLETEOS").font(.caption.weight(.bold)).tracking(2.4).foregroundStyle(Midnight.mint)
                Text("Recorder").font(.largeTitle.weight(.bold))
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).frame(width: 48, height: 48)
                    .background(Midnight.card, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Recorder settings")
        }
    }
    private var sensorCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "sensor.tag.radiowaves.forward.fill").font(.title2).foregroundStyle(Midnight.mint)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(recorder.connectionState == .connected ? Midnight.mint : .orange).frame(width: 7, height: 7)
                    Text("Polar H10").font(.headline)
                }
                Text(recorder.recordingOngoing && recorder.connectionState == .disconnected ? "Recording · phone disconnected" : recorder.connectionState.rawValue)
                    .font(.caption).foregroundStyle(Midnight.secondary)
            }
            Spacer(minLength: 4)
            if let battery = recorder.batteryPercent {
                VStack(spacing: 5) {
                    Image(systemName: battery < 20 ? "battery.25percent" : "battery.75percent")
                    Text("\(battery)%").font(.caption.monospacedDigit())
                }.foregroundStyle(battery < 20 ? Color.orange : Midnight.secondary)
                .accessibilityLabel("Last reported sensor battery \(battery) percent")
            }
        }.padding(16).midnightCard()
    }
    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Midnight.mint.opacity(0.045)).frame(width: 166, height: 166)
                Circle().stroke(Midnight.mint.opacity(0.12), lineWidth: 12).frame(width: 138, height: 138)
                Circle().stroke(Midnight.mint, lineWidth: 2.5).frame(width: 130, height: 130)
                Image(systemName: uploaded ? "checkmark" : recorder.recordingOngoing ? "heart.fill" : "heart")
                    .font(.system(size: 43, weight: .light)).foregroundStyle(Midnight.mint)
            }.accessibilityHidden(true)
            Text(title).font(.system(.title, design: .rounded).weight(.bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.subheadline).foregroundStyle(Midnight.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 6).frame(maxWidth: .infinity)
    }
    @ViewBuilder private var nearbySensors: some View {
        if recorder.scanning {
            HStack { ProgressView(); Text("Searching for nearby H10s…").font(.subheadline) }
                .foregroundStyle(Midnight.secondary)
        }
        ForEach(recorder.nearbyH10s) { sensor in
            if recorder.connectionState == .disconnected {
                Button { recorder.connect(to: sensor) } label: {
                    row(icon: "antenna.radiowaves.left.and.right", title: sensor.name, subtitle: "Tap to connect · \(sensor.id)")
                }.buttonStyle(.plain).disabled(busy)
            }
        }
    }
    private func row(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Midnight.mint).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(Midnight.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Midnight.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).midnightCard()
    }
    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.footnote).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: .infinity, alignment: .leading).midnightCard()
    }
    private func primaryAction() {
        if let file = recorder.lastSavedFile, !uploaded {
            if uploader.isConnected { Task { await upload(file) } } else { showSettings = true }
        } else if recorder.connectionState == .disconnected {
            if recorder.scanning { recorder.stopScanning() }
            else if recorder.deviceId.isEmpty { recorder.startScanning() }
            else { recorder.connect() }
        } else if ready {
            Task {
                if recorder.recordingOngoing || recorder.pendingFetchAvailable {
                    await recorder.stopFetchAndSave()
                    if let file = recorder.lastSavedFile, uploader.isConnected { await upload(file) }
                } else { await recorder.startRRRecordingAndReleasePhone() }
            }
        }
    }
    private func upload(_ file: URL) async {
        if await uploader.upload(fileURL: file) { recorder.markAthleteOSUploadConfirmed(for: file) }
    }
    private var settings: some View {
        NavigationStack {
            Form {
                Section("Polar H10") {
                    LabeledContent("Bluetooth", value: recorder.bluetoothOn ? "On" : "Off")
                    LabeledContent("Connection", value: recorder.connectionState.rawValue)
                    if let firmware = recorder.firmwareVersion { LabeledContent("Firmware", value: firmware) }
                    if recorder.connectionState == .disconnected {
                        Button(recorder.scanning ? "Stop searching" : "Find nearby H10s") {
                            if recorder.scanning { recorder.stopScanning() } else { recorder.startScanning(); showSettings = false }
                        }.disabled(!recorder.bluetoothOn || busy)
                        if !recorder.deviceId.isEmpty { Button("Reconnect saved H10") { recorder.connect() }.disabled(busy) }
                    } else {
                        Button("Disconnect H10") { recorder.disconnect() }.disabled(sensorBusy)
                        Button("Refresh recording status") { Task { await recorder.refreshRecordingStatus() } }.disabled(!ready || sensorBusy)
                    }
                }
                Section("AthleteOS") {
                    LabeledContent("Connection", value: uploader.isConnected ? "Connected" : "Not connected")
                    if !uploader.isConnected {
                        Link("Open AthleteOS", destination: URL(string: "https://athleteos-pink-sigma.vercel.app/")!)
                        Text("In AthleteOS, open Account → Overnight physiology → Connect Recorder.").font(.footnote)
                        SecureField("Connection key (optional fallback)", text: $uploader.connectionKeyDraft)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Connect with key") { Task { await uploader.connect() } }.disabled(uploader.busy || uploader.connectionKeyDraft.isEmpty)
                    } else {
                        Button("Disconnect AthleteOS", role: .destructive) { uploader.disconnect() }.disabled(uploader.busy)
                    }
                    Text(uploader.statusText).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sensor storage") {
                    if recorder.pendingFetchAvailable {
                        Button("Stop, fetch & save") {
                            Task { await recorder.stopFetchAndSave(); if let file = recorder.lastSavedFile, uploader.isConnected { await upload(file) } }
                        }.disabled(!ready || busy)
                    }
                    if recorder.athleteOSUploadConfirmed {
                        Button("Delete confirmed sensor copy", role: .destructive) { confirmDelete = true }.disabled(!ready || busy)
                    }
                    Text("The H10 copy stays protected until the file is saved on your phone and AthleteOS confirms the upload.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    Text(recorder.statusText).font(.footnote).textSelection(.enabled)
                    if let id = recorder.currentExerciseId { LabeledContent("Exercise", value: id).font(.caption) }
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete the copy on your H10?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete sensor copy", role: .destructive) { Task { await recorder.deleteSensorCopy() } }
            } message: { Text("Your saved phone file and confirmed AthleteOS copy will be kept.") }

            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }.tint(Midnight.mint).preferredColorScheme(.dark)
    }
    private var recordings: some View {
        SavedRecordingsView { file in await upload(file) }
            .environmentObject(uploader)
    }
}

private struct SavedRecordingsView: View {
    @EnvironmentObject private var uploader: AthleteOSUploader
    @Environment(\.dismiss) private var dismiss
    @State private var files: [SavedRecordingFile] = []
    @State private var loading = true
    @State private var error: String?
    let upload: (URL) async -> Void

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Loading saved recordings…") }
                if let error { Text(error).foregroundStyle(.orange) }
                if !loading && files.isEmpty && error == nil { Text("Your recordings will appear here after saving from the H10.").foregroundStyle(.secondary) }
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: uploader.isUploaded(file.url) ? "checkmark.icloud" : "doc").foregroundStyle(Midnight.mint)
                            Text(file.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        }
                        Text(uploader.isUploaded(file.url) ? "Uploaded to AthleteOS" : "Saved on this iPhone").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            ShareLink(item: file.url) { Label("Export", systemImage: "square.and.arrow.up") }
                            if !uploader.isUploaded(file.url) {
                                Button { Task { await upload(file.url) } } label: { Label("Upload", systemImage: "icloud.and.arrow.up") }
                                    .disabled(uploader.busy || !uploader.isConnected)
                            }
                        }.font(.subheadline).buttonStyle(.borderless)
                    }.padding(.vertical, 8)
                }
                if uploader.busy { ProgressView("Uploading…") }
                if let error = uploader.lastError { Text(error).font(.footnote).foregroundStyle(.orange) }
                if !uploader.isConnected { Text("Connect AthleteOS in Settings to upload saved files.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Saved recordings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do { files = try await RecordingStore().list() } catch { self.error = error.localizedDescription }
                loading = false
            }
        }.tint(Midnight.mint).preferredColorScheme(.dark)
    }
}

private struct MidnightPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.black)
            .background(Midnight.mint.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
private extension View {
    func midnightCard() -> some View {
        background(Midnight.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}
