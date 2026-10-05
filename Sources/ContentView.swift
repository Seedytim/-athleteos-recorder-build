import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: PolarH10Recorder
    @EnvironmentObject private var uploader: AthleteOSUploader

    var body: some View {
        NavigationStack {
            Form {
                Section("Polar H10") {
                    LabeledContent("Bluetooth", value: recorder.bluetoothOn ? "On" : "Off")
                    LabeledContent("Connection", value: recorder.connectionState.rawValue)
                    LabeledContent("H10 recorder", value: recorder.h10RecordingFeatureReady ? "Ready" : "Not ready")

                    if recorder.connectionState == .disconnected {
                        Button {
                            if recorder.scanning {
                                recorder.stopScanning()
                            } else {
                                recorder.startScanning()
                            }
                        } label: {
                            HStack {
                                if recorder.scanning {
                                    ProgressView()
                                }
                                Text(recorder.scanning ? "Stop scanning" : "Find nearby H10s")
                            }
                        }
                        .disabled(!recorder.bluetoothOn)

                        ForEach(recorder.nearbyH10s) { h10 in
                            Button {
                                recorder.connect(to: h10)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h10.name.isEmpty ? "Polar H10" : h10.name)
                                            .foregroundStyle(.primary)
                                        Text("ID \(h10.id)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(h10.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !recorder.deviceId.isEmpty && !recorder.scanning {
                            Button("Reconnect saved H10") {
                                recorder.connect()
                            }
                        }
                    } else {
                        if !recorder.deviceId.isEmpty {
                            LabeledContent("H10 ID", value: recorder.deviceId)
                        }

                        Button("Disconnect") {
                            recorder.disconnect()
                        }
                        .disabled(recorder.connectionState == .disconnected)
                    }

                    if let battery = recorder.batteryPercent {
                        LabeledContent("Battery", value: "\(battery)%")
                    }
                    if let firmware = recorder.firmwareVersion {
                        LabeledContent("Firmware", value: firmware)
                    }
                }

                Section("AthleteOS") {
                    LabeledContent("Connection", value: uploader.isConnected ? "Connected" : "Not connected")

                    if uploader.isConnected {
                        Text(uploader.statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let file = recorder.lastSavedFile, !recorder.athleteOSUploadConfirmed {
                            Button {
                                Task {
                                    if await uploader.upload(fileURL: file) {
                                        recorder.markAthleteOSUploadConfirmed(for: file)
                                    }
                                }
                            } label: {
                                if uploader.busy {
                                    HStack { ProgressView(); Text("Uploading…") }
                                } else {
                                    Text("Upload saved recording")
                                }
                            }
                            .disabled(uploader.busy)
                        }

                        Button("Disconnect AthleteOS", role: .destructive) {
                            uploader.disconnect()
                        }
                        .disabled(uploader.busy)
                    } else {
                        SecureField("Recorder connection key", text: $uploader.connectionKeyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            Task { await uploader.connect() }
                        } label: {
                            if uploader.busy {
                                HStack { ProgressView(); Text("Connecting…") }
                            } else {
                                Text("Connect AthleteOS")
                            }
                        }
                        .disabled(uploader.busy || uploader.connectionKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Text("Best method: open AthleteOS → Account → Overnight physiology → Connect Recorder. AthleteOS will open this app and pair it automatically. The key field above is only a fallback.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text(uploader.statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Overnight RR") {
                    LabeledContent("Recording", value: recorder.recordingOngoing ? "Running" : "Stopped")

                    if let id = recorder.currentExerciseId {
                        LabeledContent("Exercise ID", value: id)
                    }

                    Button("Start RR Recording") {
                        Task {
                            await recorder.startRRRecordingAndReleasePhone()
                        }
                    }
                    .disabled(!recorder.h10RecordingFeatureReady || recorder.recordingOngoing || recorder.fetchInProgress)

                    Button("Refresh Status") {
                        Task {
                            await recorder.refreshRecordingStatus()
                        }
                    }
                    .disabled(!recorder.h10RecordingFeatureReady || recorder.fetchInProgress)

                    Button("Stop, Fetch & Save") {
                        Task {
                            let before = recorder.lastSavedFile
                            await recorder.stopFetchAndSave()
                            await uploadIfNewOrPending(previous: before)
                        }
                    }
                    .disabled(!recorder.h10RecordingFeatureReady || recorder.fetchInProgress || uploader.busy)

                    if recorder.pendingFetchAvailable && !recorder.recordingOngoing && recorder.lastSavedFile == nil {
                        Button("Retry Fetch") {
                            Task {
                                let before = recorder.lastSavedFile
                                await recorder.retryFetchAndSave()
                                await uploadIfNewOrPending(previous: before)
                            }
                        }
                        .disabled(!recorder.h10RecordingFeatureReady || recorder.fetchInProgress || uploader.busy)
                    }

                    if recorder.fetchInProgress {
                        HStack {
                            ProgressView()
                            Text("Reading H10…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let file = recorder.lastSavedFile {
                        LabeledContent("Saved file", value: file.lastPathComponent)
                        LabeledContent("AthleteOS", value: recorder.athleteOSUploadConfirmed ? "Confirmed" : "Waiting")

                        if recorder.athleteOSUploadConfirmed {
                            Button("Delete Sensor Copy", role: .destructive) {
                                Task {
                                    await recorder.deleteSensorCopy()
                                }
                            }
                        } else {
                            Text("The H10 copy stays protected until AthleteOS confirms the upload.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Status") {
                    Text(recorder.statusText)

                    if let error = recorder.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }

                    if uploader.isConnected || uploader.busy {
                        Text(uploader.statusText)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Safety") {
                    Text("The raw file is saved on the iPhone first. AthleteOS must confirm receipt before the Recorder allows the H10 sensor copy to be deleted.")
                        .font(.footnote)
                }
            }
            .navigationTitle("AthleteOS Recorder")
        }
    }

    private func uploadIfNewOrPending(previous: URL?) async {
        guard let file = recorder.lastSavedFile else { return }
        let isNew = previous?.standardizedFileURL != file.standardizedFileURL
        guard isNew || !recorder.athleteOSUploadConfirmed else { return }
        guard uploader.isConnected else { return }

        if await uploader.upload(fileURL: file) {
            recorder.markAthleteOSUploadConfirmed(for: file)
        }
    }
}
