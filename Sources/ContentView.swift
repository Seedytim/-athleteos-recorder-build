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
    @EnvironmentObject private var notifications: RecorderNotifications
    @State private var actionGate = NightActionGate()
    @State private var nightActionWasEnd = false
    @State private var showSettings = false
    @State private var showRecordings = false
    @State private var savedFiles: [SavedRecordingFile] = []
    @State private var uploadPassInProgress = false
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .title) private var heroDiameter = 132.0

    private var savedSummary: String {
        let count = savedFiles.count
        let uploadedCount = savedFiles.filter { uploader.isUploaded($0.url) }.count
        if count == 0 { return "No recordings yet" }
        return uploadedCount > 0 ? "\(count) waiting · \(uploadedCount) verified" : "\(count) waiting to archive"
    }
    private var latestFile: URL? { recorder.lastSavedFile ?? savedFiles.first?.url }
    private var latestUploaded: Bool { latestFile.map { uploader.isUploaded($0) } ?? false }

    private var sensorBusy: Bool { actionGate.running || recorder.nightActionInProgress || recorder.fetchInProgress || recorder.pftpOperationInProgress || recorder.recoveringConnection }
    private var busy: Bool { sensorBusy || uploader.busy }
    private var ready: Bool { recorder.h10RecordingFeatureReady && recorder.fileTransferFeatureReady }
    private var uploaded: Bool {
        guard let file = recorder.lastSavedFile else { return false }
        return uploader.isUploaded(file)
    }
    private var title: String {
        if recorder.fetchInProgress { return "Saving your recording" }
        if uploader.busy { return uploader.isConnected ? "Uploading your recording" : "Connecting to AthleteOS" }
        if sensorBusy { return "Talking to your H10" }
        if recorder.recordingOngoing { return "Recording on H10" }
        if recorder.lastSavedFile != nil { return uploaded ? "Recording archived" : "Recording saved" }
        if recorder.pendingFetchAvailable { return "Recording on your H10" }
        if recorder.connectionState == .connecting { return "Connecting your H10" }
        if recorder.connectionState == .connected && !ready { return recorder.preparationTimedOut ? "Let’s reconnect your H10" : "Preparing your H10" }
        if uploader.lastUploadedRecordingId != nil && savedFiles.isEmpty { return "Night archived" }
        return ready ? "Ready to record" : "Let’s get connected"
    }
    private var subtitle: String {
        if recorder.fetchInProgress { return "Keep your H10 nearby while the raw recording is saved to your phone." }
        if uploader.busy { return uploader.statusText }
        if sensorBusy { return recorder.statusText }
        if recorder.recordingOngoing { return "Your sensor is recording independently. Reconnect when you’re ready to finish." }
        if recorder.lastSavedFile != nil { return uploaded ? "AthleteOS has verified the raw recording." : "Your raw file is safe on this phone and will archive when AthleteOS is connected." }
        if recorder.pendingFetchAvailable { return "Reconnect to check or finish the recording and save it to your phone." }
        if recorder.connectionState == .connected && !ready { return recorder.preparationMessage }
        if uploader.lastUploadedRecordingId != nil && savedFiles.isEmpty { return uploader.statusText }
        return ready ? "Your Polar H10 is ready to record RR intervals." : "Wear your H10 with the strap moistened, then connect to begin."
    }
    private var actionTitle: String {
        if actionGate.running { return nightActionWasEnd ? "Ending night…" : "Starting night…" }
        if recorder.fetchInProgress { return "Ending night…" }
        if sensorBusy { return recorder.pendingFetchAvailable ? "Ending night…" : "Starting night…" }
        if recorder.connectionState == .connecting { return recorder.pendingFetchAvailable ? "Connecting to end night…" : "Connecting…" }
        if recorder.recordingOngoing || recorder.pendingFetchAvailable { return "End night" }
        if recorder.connectionState == .disconnected { return recorder.deviceId.isEmpty ? "Set up H10" : "Start night" }
        if !ready { return "Start night" }
        return "Start night"
    }
    private var actionIcon: String {
        if recorder.lastSavedFile != nil && !uploaded && recorder.connectionState != .connected { return "antenna.radiowaves.left.and.right" }
        if recorder.connectionState != .connected { return "antenna.radiowaves.left.and.right" }
        return recorder.recordingOngoing || recorder.pendingFetchAvailable ? "stop.fill" : "play.fill"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
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
                    .disabled(sensorBusy || !recorder.bluetoothOn)
                    nearbySensors
                    if let error = recorder.lastError { notice(error, icon: "exclamationmark.triangle", color: .orange) }
                    if let error = uploader.lastError { notice(error, icon: "icloud.slash", color: .orange) }
                    VStack(spacing: 12) {
                        Button { showRecordings = true } label: {
                            row(icon: "list.bullet", title: "Saved recordings", subtitle: savedSummary)
                        }.buttonStyle(.plain)
                        Button {
                            if latestFile != nil { showRecordings = true } else { showSettings = true }
                        } label: {
                            latestRecordingRow
                        }.buttonStyle(.plain)
                    }
                    Label("Saved on your phone before upload", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(Midnight.secondary)
                        .frame(maxWidth: .infinity).padding(.bottom, 14)
                }
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Midnight.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { settings }
            .sheet(isPresented: $showRecordings, onDismiss: { Task { await refreshSavedFiles() } }) { recordings }
            .onOpenURL { url in
                Task { _ = await uploader.handleConnectionURL(url) }
            }
            .onChange(of: recorder.pendingFetchAvailable) { _ in syncReminders() }
            .onChange(of: recorder.recordingOngoing) { _ in syncReminders() }
            .task {
                syncReminders()
                await notifications.refreshAuthorization()
                // Retry transient network/archive failures while this view is active.
                while !Task.isCancelled {
                    if scenePhase == .active {
                        await processPendingUploads()
                        await recorder.cleanupQueuedSensorCopies()
                        await refreshSavedFiles()
                    }
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                }
            }
            .onChange(of: recorder.lastSavedFile) { _ in
                Task {
                    await processPendingUploads()
                    await refreshSavedFiles()
                }
            }
            .onChange(of: uploader.isConnected) { connected in
                if connected { Task { await processPendingUploads() } }
            }
            .onChange(of: recorder.connectionState) { state in
                if state == .connected { Task { await recorder.cleanupQueuedSensorCopies() } }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        syncReminders()
                        await notifications.refreshAuthorization()
                        await processPendingUploads()
                        await recorder.cleanupQueuedSensorCopies()
                        await refreshSavedFiles()
                    }
                }
            }
        }
        .tint(Midnight.mint).preferredColorScheme(.dark)
    }

    private func refreshSavedFiles() async {
        do { savedFiles = try await RecordingStore.shared.list() }
        catch { /* The recordings sheet presents storage errors with retry context. */ }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Text("AthleteOS Recorder")
                .font(.system(.title2).weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.white)
                .accessibilityLabel("Recorder settings")
        }
    }
    private var connectionLabel: String {
        if recorder.recordingOngoing && recorder.connectionState == .disconnected { return "Recording offline" }
        if recorder.scanning { return "Searching" }
        return recorder.connectionState.rawValue
    }
    private var sensorCard: some View {
        HStack(spacing: 14) {
            H10SensorIllustration().frame(width: 58, height: 38).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(recorder.connectionState == .connected ? Midnight.mint : .orange)
                        .frame(width: 8, height: 8)
                    (Text("Polar H10 · ").foregroundColor(.white) + Text(connectionLabel)
                        .foregroundColor(recorder.connectionState == .connected ? Midnight.mint : Midnight.secondary))
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                if let battery = recorder.batteryPercent {
                    Label("Battery \(battery)%", systemImage: battery < 20 ? "battery.25percent" : "battery.75percent")
                        .font(.caption).foregroundStyle(battery < 20 ? Color.orange : Midnight.secondary)
                        .accessibilityLabel("Last reported sensor battery \(battery) percent")
                } else {
                    Text(recorder.bluetoothOn ? "Battery available after connection" : "Turn on Bluetooth to connect")
                        .font(.caption).foregroundStyle(Midnight.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).midnightCard()
    }
    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Midnight.mint.opacity(0.13), Midnight.mint.opacity(0.025)], center: .center, startRadius: 40, endRadius: heroDiameter * 0.65))
                    .frame(width: heroDiameter + 26, height: heroDiameter + 26)
                Circle().stroke(Midnight.mint.opacity(0.055), lineWidth: 14)
                    .frame(width: heroDiameter + 8, height: heroDiameter + 8)
                Circle().stroke(Midnight.mint, lineWidth: 3)
                    .frame(width: heroDiameter, height: heroDiameter)
                    .shadow(color: Midnight.mint.opacity(0.18), radius: 18)
                Image(systemName: uploaded ? "checkmark" : recorder.recordingOngoing ? "heart.fill" : "heart")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(Midnight.mint)
            }.accessibilityHidden(true).padding(.bottom, 2)
            Text(title).font(.system(.title).weight(.bold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.subheadline).foregroundStyle(Midnight.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 310)
        }.padding(.top, 6).padding(.bottom, 2).frame(maxWidth: .infinity)
    }
    private var latestRecordingRow: some View {
        HStack(spacing: 14) {
            Image(systemName: latestUploaded ? "icloud.and.arrow.up" : "icloud")
                .font(.title3).foregroundStyle(Midnight.mint).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(latestFile == nil ? "AthleteOS connection" : "Latest recording")
                    .font(.caption).foregroundStyle(Midnight.secondary)
                Text(latestFile != nil ? (latestUploaded ? "Uploaded to AthleteOS" : "Saved on your phone") : (uploader.isConnected ? "Connected to AthleteOS" : "Connect to AthleteOS"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Midnight.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).midnightCard()
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
    private func syncReminders() {
        notifications.syncNight(pending: recorder.recordingOngoing || recorder.pendingFetchAvailable,
            startedAt: UserDefaults.standard.object(forKey: "h10.startedAt") as? Date)
    }

    private func primaryAction() {
        guard actionGate.begin() else { return }
        nightActionWasEnd = recorder.recordingOngoing || recorder.pendingFetchAvailable
        Task {
            defer { actionGate.finish() }
            await notifications.refreshAuthorization()
            // CoreBluetooth may still be initializing during a widget cold launch.
            for _ in 0..<10 where !recorder.bluetoothOn {
                try? await Task.sleep(for: .milliseconds(200))
            }
            await recorder.performNightAction()
            syncReminders()
            let night = recorder.currentExerciseId ?? "setup"
            if let error = recorder.lastError {
                await notifications.event(key: "action-\(night)", title: "Recorder needs your attention", body: error)
            } else if recorder.recordingOngoing {
                await notifications.event(key: "started-\(night)", title: "Night recording confirmed",
                    body: "Your H10 confirmed recording. It can record independently of your phone.")
            }
            await processPendingUploads()
            if let file = recorder.lastSavedFile, !uploader.isConnected {
                await notifications.event(key: "upload-\(file.lastPathComponent)", title: "Recording saved on your iPhone",
                    body: "Connect AthleteOS in Recorder Settings to archive it. Your raw recording remains safely on your phone.")
            }
            await recorder.cleanupQueuedSensorCopies()
            await refreshSavedFiles()
        }
    }

    private func upload(_ file: URL) async {
        let store = RecordingStore.shared
        guard let receipt = await uploader.upload(fileURL: file) else {
            await notifications.event(key: "upload-\(file.lastPathComponent)", title: "Recording saved on your iPhone",
                body: "AthleteOS has not verified the archive yet. Your raw file is retained; Recorder will retry while open.")
            return
        }
        do {
            let identity = try await store.confirmArchive(file, receipt: receipt)
            recorder.markArchiveConfirmedAndLocalDeleted(for: file, identity: identity)
            syncReminders()
            await notifications.event(key: "archived-\(receipt.recordingID)", title: "Night safely archived",
                body: "AthleteOS verified your raw recording. The iPhone copy has been removed; H10 cleanup runs when connected.")
            await recorder.cleanupQueuedSensorCopies()
            await refreshSavedFiles()
        } catch {
            uploader.reportLocalCleanupError(error)
            await notifications.event(key: "cleanup-\(file.lastPathComponent)", title: "Recording cleanup will retry",
                body: "Your recording is retained until archive verification and local cleanup finish safely.")
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
                Section("Notifications") {
                    if notifications.enabled {
                        Toggle("Recorder notifications", isOn: $notifications.enabled)
                    } else {
                        Button("Enable notifications") { Task { await notifications.enable() } }
                    }
                    if notifications.authorization == .denied {
                        Text("Allow notifications in iPhone Settings to receive reminders and recording alerts.")
                        Link("Open iPhone Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                    if notifications.enabled {
                        Toggle("Evening reminder", isOn: $notifications.eveningEnabled)
                        if notifications.eveningEnabled {
                            DatePicker("Start reminder", selection: $notifications.eveningTime, displayedComponents: .hourAndMinute)
                        }
                        Toggle("Morning reminder", isOn: $notifications.morningEnabled)
                        if notifications.morningEnabled {
                            DatePicker("End reminder", selection: $notifications.morningTime, displayedComponents: .hourAndMinute)
                        }
                    }
                    Text("Morning reminders are scheduled only for a night awaiting collection. Alerts confirm recording and verified archival, or tell you when attention is needed. Reminder times follow your iPhone's local time.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error = notifications.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                }
                Section("Sensor storage") {
                    if recorder.pendingFetchAvailable {
                        Button("Stop, fetch & save") {
                            Task { await recorder.stopFetchAndSave(); if let file = recorder.lastSavedFile, uploader.isConnected { await upload(file) } }
                        }.disabled(!ready || busy)
                    }
                    if recorder.pendingSensorCleanupCount > 0 {
                        Text("\(recorder.pendingSensorCleanupCount) archived H10 recording(s) waiting for automatic cleanup.").font(.footnote)
                    }
                    Text("H10 copies are removed automatically only after AthleteOS verifies the exact raw file. Cleanup retries when the H10 reconnects.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    Text(recorder.statusText).font(.footnote).textSelection(.enabled)
                    if let id = recorder.currentExerciseId { LabeledContent("Exercise", value: id).font(.caption) }
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)

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
                            Group {
                                Button { Task { await upload(file.url) } } label: { Label(uploader.isUploaded(file.url) ? "Retry cleanup" : "Upload", systemImage: "icloud.and.arrow.up") }
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
                do { files = try await RecordingStore.shared.list() } catch { self.error = error.localizedDescription }
                loading = false
            }
        }.tint(Midnight.mint).preferredColorScheme(.dark)
    }
}

private struct MidnightPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.black)
             .background(LinearGradient(colors: [Midnight.mint, Color(red: 0.33, green: 0.96, blue: 0.72)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 18))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
private extension View {
    func midnightCard() -> some View {
        background(LinearGradient(colors: [Midnight.card, Midnight.card.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

// Vector artwork stays sharp at every screen size without a bundled bitmap.
private struct H10SensorIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.065))
                .frame(width: 58, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.2), lineWidth: 1))
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.035))
                .frame(width: 40, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.24), lineWidth: 1))
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.065)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.28), lineWidth: 0.6))
        }.shadow(color: .black.opacity(0.5), radius: 4, y: 3)
    }
}
