import SwiftUI

private enum RecorderTheme {
    static let background = Color(red: 0.025, green: 0.035, blue: 0.035)
    static let card = Color(red: 0.060, green: 0.078, blue: 0.078)
    static let mint = Color(red: 0.31, green: 0.94, blue: 0.68)
    static let secondary = Color(red: 0.63, green: 0.69, blue: 0.68)
}

struct ContentView: View {
    @EnvironmentObject private var recorder: RawH10Capture

    var body: some View {
        ZStack {
            RecorderTheme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                header
                Spacer(minLength: 8)
                state
                primaryButton
                sensorPicker
                Spacer()
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 560)
        }
        .preferredColorScheme(.dark)
        .tint(RecorderTheme.mint)
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text("AthleteOS Recorder")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("RAW H10 DATA")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(RecorderTheme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var state: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill((recorder.captureRequested ? RecorderTheme.mint : RecorderTheme.card).opacity(0.14))
                    .frame(width: 150, height: 150)

                Image(systemName: recorder.captureRequested ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle")
                    .font(.system(size: 58, weight: .medium))
                    .foregroundStyle(recorder.captureRequested ? RecorderTheme.mint : .white)
            }

            VStack(spacing: 7) {
                Text(mainTitle)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(recorder.statusText)
                    .font(.subheadline)
                    .foregroundStyle(recorder.lastError == nil ? RecorderTheme.secondary : Color.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if recorder.captureRequested {
                captureReadout
            } else {
                sensorReadout
            }
        }
    }

    private var mainTitle: String {
        if recorder.captureRequested {
            return recorder.capturing ? "Recording raw data" : "Restoring raw capture"
        }
        if recorder.deviceId.isEmpty { return "Pair your H10 once" }
        if recorder.connectionState == .connected { return "Ready" }
        return "Ready to record"
    }

    private var captureReadout: some View {
        VStack(spacing: 6) {
            if let started = recorder.captureStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(duration(from: started, to: context.date))
                        .font(.system(.title2, design: .monospaced).weight(.medium))
                }
            }

            Text("ECG \(compact(recorder.ecgSamples))  ·  ACC \(compact(recorder.accSamples))  ·  RR \(compact(recorder.hrRecords))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(RecorderTheme.secondary)
        }
        .padding(.top, 2)
    }

    private var sensorReadout: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(sensorStatus)
                .font(.caption)
                .foregroundStyle(RecorderTheme.secondary)
            if let battery = recorder.batteryPercent {
                Text("· \(battery)%")
                    .font(.caption)
                    .foregroundStyle(RecorderTheme.secondary)
            }
        }
    }

    private var primaryButton: some View {
        Button {
            recorder.primaryAction()
        } label: {
            HStack(spacing: 10) {
                if recorder.connectionState == .connecting && !recorder.captureRequested {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: recorder.captureRequested ? "stop.fill" : "record.circle")
                        .font(.headline)
                }
                Text(recorder.primaryButtonTitle)
                    .font(.headline.weight(.bold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(RecorderTheme.mint)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!recorder.bluetoothOn && !recorder.captureRequested)
        .opacity((!recorder.bluetoothOn && !recorder.captureRequested) ? 0.45 : 1)
    }

    @ViewBuilder
    private var sensorPicker: some View {
        if !recorder.nearbyH10s.isEmpty && !recorder.captureRequested {
            VStack(spacing: 10) {
                ForEach(recorder.nearbyH10s) { h10 in
                    Button {
                        recorder.select(h10)
                    } label: {
                        HStack {
                            Image(systemName: "sensor.tag.radiowaves.forward")
                                .foregroundStyle(RecorderTheme.mint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h10.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text(h10.id)
                                    .font(.caption2)
                                    .foregroundStyle(RecorderTheme.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(RecorderTheme.secondary)
                        }
                        .padding(15)
                        .background(RecorderTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if !recorder.deviceId.isEmpty && !recorder.captureRequested {
                Button("Change H10") {
                    recorder.forgetSensor()
                    recorder.startScanning()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecorderTheme.secondary)
            }

            Text("Recorder only captures and preserves raw ECG, accelerometer and RR data. It does not score or interpret it.")
                .font(.caption2)
                .foregroundStyle(RecorderTheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 2)
        }
    }

    private var sensorStatus: String {
        if recorder.deviceId.isEmpty { return recorder.scanning ? "Searching for H10" : "No H10 paired" }
        switch recorder.connectionState {
        case .connected:
            return recorder.deviceName
        case .connecting:
            return "Connecting \(recorder.deviceName)"
        case .disconnected:
            return "\(recorder.deviceName) saved"
        }
    }

    private var connectionColor: Color {
        if recorder.connectionState == .connected { return RecorderTheme.mint }
        if recorder.connectionState == .connecting { return .yellow }
        return .orange
    }

    private func duration(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
    }

    private func compact(_ value: UInt64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return String(value)
    }
}
