# AthleteOS Recorder build mirror

## Phone-owned live recording (unreleased)

ECG/ACC preserve raw sensor nanoseconds unchanged. Each packet also records exact
nanoseconds as strings, precise host receipt milliseconds, monotonic uptime,
packet bounds and a reconnect segment ID. Receipt time references the LAST
sample, not the first. This is a Bluetooth receipt estimate, not hardware clock
synchronization. The backend isolates capture clocks, refuses reset/clock-step
anchors and never invents a clock origin when anchors are missing. Old archives
retain their original lower-precision anchors; they are not retroactively fixed.

New nights stream RR through the Bluetooth Heart Rate Service alongside ECG and
accelerometer data. All three channels must produce fresh packets before the UI
claims a healthy recording. No H10 exercise is started, fetched, or deleted by
the new night action. Old sensor recordings remain in the explicit legacy
recovery path; installing this change does not erase them.

RR notifications, receipt times and contact flags are saved in bounded local
chunks. ECG/ACC and HR writes are flushed at most approximately every five
seconds or 64 KiB. End night works without a Bluetooth connection and creates a
stable schema-2 RR export containing every interrupted segment for that night.
Upload retries are idempotent and local deletion requires exact SHA receipts.
The companion backend schema-2 parser must deploy before releasing this app.

Keep Bluetooth on, the phone nearby, and Recorder running (screen lock is fine;
do not force-quit). A lost BLE connection, phone shutdown, or terminated process
can lose new samples. Received durable chunks survive; missed samples cannot be
recovered without sensor buffering. The app reconnects where iOS permits it and
does not fabricate coverage. Live RR beat times are estimates anchored to host
notification receipt, not device-timestamped ECG R peaks.

Acceptance gate: locked-screen capture, a 20-second BLE interruption, app
termination/relaunch, End with BLE off, offline upload/retry, and one full-night
run. Native CI alone cannot prove these physical-device behaviours. This branch
does not change the IPA or SideStore feed and is not approved for release.

This public repository exists only to build the unsigned **AthleteOS Recorder** iPhone app with GitHub-hosted macOS runners.

It intentionally contains only the native Recorder client source and build workflow. It does **not** contain AthleteOS database credentials, private coaching data, Supabase service keys, ingest tokens, or private AthleteOS application source.

The app records Polar H10 sensor-side RR data, saves the raw recording locally, and can upload it to the AthleteOS overnight-ingestion endpoint after the user explicitly pairs the Recorder from AthleteOS.

The resulting unsigned IPA is published at `dist/AthleteOSRecorder.ipa` for SideStore to sign/install with the user's own Apple account.


## Overnight lifecycle (2.0.2)

After pairing and the AthleteOS connection, Start night owns reconnect, service
preparation, H10 start/status verification, and phone release. End night owns
reconnect, stop, bounded fetch retries, durable raw save and upload. An offline
AthleteOS does not discard raw files or prevent the next night.

Verified SHA-256 receipts are journaled before deleting local raw data. Sensor
cleanup is scoped to the original H10 identity, remains queued after failure and
can resume after an app restart. Processing failure or insufficient HRV data does
not invalidate raw archival. An unknown exercise is never substituted for the
expected night.

## Validation and releases

Automatic native validation runs all safety/connection checks, real uploader
transport regressions and simulator compilation on macOS. A separate Linux
workflow provides portable feedback; its runner queue does not gate native releases.
Dependencies are pinned and cached. Validation never packages an IPA.

Release is manual only and remains on hold until the owner explicitly approves
publication. Validation never updates the IPA or SideStore feed. A manually
approved release reruns safety checks, simulator and device builds, then publishes
the IPA with SHA-256/source metadata. It refuses publication if main changed.

## Widget and notifications

The embedded WidgetKit extension provides small and medium Home Screen widgets.
Its single control opens the app and runs the same guarded night action. It does
not cache or guess whether the H10 is recording, and needs no shared App Group or
Bluetooth connection in the extension. The foreground app owns Bluetooth and raw
storage. Keep the extension when SideStore signs the eventual approved release.

Enable local notifications in Recorder Settings. Defaults are 21:00 evening and
07:00 morning, editable in local time. Evening prompts pause while a night awaits
collection; the one-off morning prompt is cancelled after a durable save. An old
pending night is not moved forward into another morning on every app launch.
Verified start/archive and attention alerts are deduplicated across app restarts.
A notification tap opens Recorder for review; it never implicitly stops a night.
These are local Recorder notifications, not server-originated AthleteOS/APNs push.

Device acceptance must verify widget availability after SideStore signing, cold
launch/foreground taps, repeated taps, permission denial/re-enabling, reminders
with the app closed, and notifications across offline upload/retry and app restart.
Automated compile cannot prove signing or iOS delivery on the user's phone.

## Real H10 acceptance test

1. Pair once and connect AthleteOS. Keep the moistened strap worn.
2. Start night while disconnected: confirm Recording on H10 and phone release.
3. Force-quit and reopen: End night must remain available. Let it record 10 minutes.
4. End night once: reconnect/stop/fetch/archive should run without more taps.
5. Check the backend verified archive and matching raw SHA. Check local removal
   and automatic H10 cleanup (or retained cleanup journal after a failed removal).
6. Repeat with internet disabled at End: local raw must remain. Re-enable internet
   with Recorder active; retry should archive and clean up without another fetch.

Automated tests simulate transport loss/duplicate responses and storage/cleanup
failures; they do not prove physical Bluetooth behaviour, complete overnight
transfer timing, battery life, or H10 firmware response after a forced app exit.
