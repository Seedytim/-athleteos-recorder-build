# AthleteOS Recorder build mirror

This public repository exists only to build the unsigned **AthleteOS Recorder** iPhone app with GitHub-hosted macOS runners.

It intentionally contains only the native Recorder client source and build workflow. It does **not** contain AthleteOS database credentials, private coaching data, Supabase service keys, ingest tokens, or private AthleteOS application source.

The app records Polar H10 sensor-side RR data, saves the raw recording locally, and can upload it to the AthleteOS overnight-ingestion endpoint after the user explicitly pairs the Recorder from AthleteOS.

The resulting unsigned IPA is published at `dist/AthleteOSRecorder.ipa` for SideStore to sign/install with the user's own Apple account.
