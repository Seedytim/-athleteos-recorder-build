import Foundation
import Combine
import Security
import CryptoKit

struct VerifiedResearchArchiveReceipt: Sendable, Equatable {
    let serverCaptureId: String
    let clientCaptureId: UUID
    let archiveSHA256: String
    let fileCount: Int
    let totalBytes: UInt64
}

private struct PreparedResearchFile {
    let file: ResearchArchiveFile
    let sha256: String
    let byteCount: UInt64
}

@MainActor
final class AthleteOSUploader: ObservableObject {
    @Published var connectionKeyDraft = ""
    @Published private(set) var isConnected = false
    @Published private(set) var busy = false
    @Published private(set) var statusText = "Connect AthleteOS once to upload saved RR recordings automatically."
    @Published private(set) var lastUploadedRecordingId: String?
    @Published private(set) var lastError: String?
    @Published private(set) var uploadedFileNames: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "athleteos.uploadedFileNames") ?? [])

    func isUploaded(_ file: URL) -> Bool { uploadedFileNames.contains(file.lastPathComponent) }

    private func rememberUpload(_ file: URL) {
        uploadedFileNames.insert(file.lastPathComponent)
        UserDefaults.standard.set(Array(uploadedFileNames), forKey: "athleteos.uploadedFileNames")
    }

    private let session: URLSession
    private let tokenProvider: (() -> String?)?
    private let endpoint = URL(string: "https://bjdpzxbfpgmzwcdgzqso.supabase.co/functions/v1/ingest-hrv-logger")!
    private let researchEndpoint = URL(string: "https://bjdpzxbfpgmzwcdgzqso.supabase.co/functions/v1/ingest-recorder-raw")!
    private let keychainService = "nz.co.athleteos.recorder"
    private let keychainAccount = "overnight-ingest-token"

    init(session: URLSession = .shared, tokenProvider: (() -> String?)? = nil) {
        self.session = session
        self.tokenProvider = tokenProvider
        if let path = UserDefaults.standard.string(forKey: "h10.lastSavedFilePath"),
           let exercise = UserDefaults.standard.string(forKey: "h10.exerciseId"),
           UserDefaults.standard.string(forKey: "h10.uploadedExerciseId") == exercise {
            uploadedFileNames.insert(URL(fileURLWithPath: path).lastPathComponent)
            UserDefaults.standard.set(Array(uploadedFileNames), forKey: "athleteos.uploadedFileNames")
        }
        isConnected = readToken() != nil
        if isConnected {
            statusText = "AthleteOS connection key saved securely on this iPhone."
        }
    }

    func handleConnectionURL(_ url: URL) async -> Bool {
        guard !busy else { return false }
        guard url.scheme == "athleteos-recorder", url.host == "connect" else {
            statusText = "That AthleteOS link is not a Recorder connection link."
            return false
        }
        guard
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let token = parts.queryItems?.first(where: { $0.name == "token" })?.value,
            !token.isEmpty
        else {
            statusText = "AthleteOS did not provide a Recorder connection key."
            return false
        }

        connectionKeyDraft = token
        await connect()
        return isConnected
    }

    func connect() async {
        guard !busy else { return }
        lastError = nil
        let token = connectionKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32 else {
            statusText = "Paste the Recorder connection key from AthleteOS first."
            return
        }

        busy = true
        defer { busy = false }

        do {
            var request = URLRequest(url: endpoint, timeoutInterval: 90)
            request.httpMethod = "GET"
            request.setValue(token, forHTTPHeaderField: "X-AthleteOS-Ingest-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UploadError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode), responseIsOk(data) else {
                throw UploadError.rejected(status: http.statusCode, detail: responseDetail(data))
            }

            try saveToken(token)
            connectionKeyDraft = ""
            isConnected = true
            statusText = "Connected to AthleteOS. Pending recordings retry while Recorder is open or active."
        } catch {
            statusText = "AthleteOS connection failed: \(friendly(error))"
            lastError = statusText
        }
    }

    func disconnect() {
        guard !busy else { return }
        lastError = nil
        deleteToken()
        connectionKeyDraft = ""
        isConnected = false
        lastUploadedRecordingId = nil
        statusText = "AthleteOS disconnected. Local recordings are unchanged."
    }

    func upload(fileURL: URL) async -> VerifiedArchiveReceipt? {
        guard !busy else { return nil }
        lastError = nil
        guard let token = readToken() else {
            isConnected = false
            statusText = "Connect AthleteOS to archive pending recordings."
            return nil
        }

        busy = true
        statusText = "Archiving raw RR recording in AthleteOS…"
        defer { busy = false }

        do {
            let localData = try Data(contentsOf: fileURL)
            let digest = SHA256.hash(data: localData)
            let localSHA = digest.map { String(format: "%02x", $0) }.joined()

            var request = URLRequest(url: endpoint, timeoutInterval: 90)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(fileURL.lastPathComponent, forHTTPHeaderField: "X-File-Name")
            request.setValue(token, forHTTPHeaderField: "X-AthleteOS-Ingest-Token")

            let (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
            guard let http = response as? HTTPURLResponse else {
                throw UploadError.invalidResponse
            }

            if http.statusCode == 401 {
                isConnected = false
                throw UploadError.rejected(status: 401, detail: "Connection key rejected. Reconnect from AthleteOS.")
            }
            guard (200..<300).contains(http.statusCode), responseIsOk(responseData) else {
                throw UploadError.rejected(status: http.statusCode, detail: responseDetail(responseData))
            }

            guard let receipt = UploadReceipt.verifiedArchive(in: responseData, expectedSHA256: localSHA) else {
                throw UploadError.rejected(
                    status: http.statusCode,
                    detail: "AthleteOS did not verify the exact raw file. The iPhone copy was retained."
                )
            }

            guard try Data(contentsOf: fileURL) == localData else {
                throw UploadError.rejected(status: http.statusCode, detail: "The local raw file changed during upload. It was retained.")
            }
            let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
            let duplicate = json?["duplicate"] as? Bool ?? false
            lastUploadedRecordingId = receipt.recordingID
            rememberUpload(fileURL)
            isConnected = true
            switch receipt.processingState {
            case "insufficient_data":
                statusText = "Raw recording archived safely. There was not enough usable data for HRV analysis."
            case "error":
                statusText = "Raw recording archived safely. HRV analysis can be retried separately."
            default:
                statusText = duplicate
                    ? "AthleteOS verified this raw recording was already archived."
                    : "Raw recording archived and verified in AthleteOS."
            }
            return receipt
        } catch {
            statusText = "AthleteOS archive failed: \(friendly(error)). The iPhone copy is retained."
            lastError = statusText
            return nil
        }
    }

    func uploadResearchCapture(_ archive: ResearchCaptureArchive) async -> VerifiedResearchArchiveReceipt? {
        guard !busy else { return nil }
        lastError = nil
        guard let token = readToken() else {
            isConnected = false
            statusText = "Connect AthleteOS to archive pending raw streams."
            return nil
        }

        busy = true
        statusText = "Archiving raw ECG and motion in AthleteOS…"
        defer { busy = false }

        do {
            let prepared = try archive.files.map { file -> PreparedResearchFile in
                let data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
                guard data.count <= 8 * 1024 * 1024 else {
                    throw UploadError.rejected(
                        status: 413,
                        detail: "\(file.fileName) is too large for the raw archive protocol. It was retained on this iPhone."
                    )
                }
                let sha = Self.sha256Hex(data)
                return PreparedResearchFile(file: file, sha256: sha, byteCount: UInt64(data.count))
            }.sorted { $0.file.fileName < $1.file.fileName }

            guard !prepared.isEmpty else {
                throw UploadError.rejected(status: 400, detail: "Raw capture has no files to archive.")
            }

            let archiveSHA = Self.canonicalResearchArchiveSHA(prepared)
            let totalBytes = prepared.reduce(UInt64(0)) { $0 + $1.byteCount }

            let manifestEncoder = JSONEncoder()
            manifestEncoder.dateEncodingStrategy = .iso8601
            manifestEncoder.outputFormatting = [.sortedKeys]
            let manifestData = try manifestEncoder.encode(archive.manifest)
            guard let manifestObject = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
                throw UploadError.invalidResponse
            }

            let formatter = ISO8601DateFormatter()
            var begin: [String: Any] = [
                "action": "begin",
                "client_capture_id": archive.captureId.uuidString.lowercased(),
                "exercise_id": archive.manifest.device.internalRRExerciseId,
                "schema_version": archive.manifest.schemaVersion,
                "source_state": archive.manifest.state,
                "started_at": formatter.string(from: archive.manifest.startedAt),
                "archive_sha256": archiveSHA,
                "manifest": manifestObject,
                "files": prepared.map {
                    [
                        "file_name": $0.file.fileName,
                        "channel": $0.file.channel ?? NSNull(),
                        "record_encoding": $0.file.recordEncoding ?? NSNull(),
                        "byte_count": NSNumber(value: $0.byteCount),
                        "sha256": $0.sha256,
                    ] as [String: Any]
                },
            ]
            if let endedAt = archive.manifest.endedAt {
                begin["ended_at"] = formatter.string(from: endedAt)
            } else {
                begin["ended_at"] = NSNull()
            }

            let beginData = try JSONSerialization.data(withJSONObject: begin, options: [.sortedKeys])
            let beginResponse = try await sendResearchJSON(beginData, token: token)
            if let receipt = Self.researchReceipt(
                beginResponse,
                expectedClientCaptureId: archive.captureId,
                expectedArchiveSHA: archiveSHA,
                expectedFileCount: prepared.count,
                expectedTotalBytes: totalBytes,
                requireVerified: true
            ) {
                isConnected = true
                statusText = "AthleteOS verified this raw stream capture was already archived."
                return receipt
            }

            let beginJSON = try Self.jsonObject(beginResponse)
            let missing = Set((beginJSON["missing_files"] as? [String]) ?? prepared.map { $0.file.fileName })

            for item in prepared where missing.contains(item.file.fileName) {
                var request = URLRequest(url: researchEndpoint, timeoutInterval: 120)
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(token, forHTTPHeaderField: "X-AthleteOS-Ingest-Token")
                request.setValue("file", forHTTPHeaderField: "X-Recorder-Action")
                request.setValue(archive.captureId.uuidString.lowercased(), forHTTPHeaderField: "X-Capture-ID")
                request.setValue(item.file.fileName, forHTTPHeaderField: "X-File-Name")
                request.setValue(item.sha256, forHTTPHeaderField: "X-File-SHA256")

                let (responseData, response) = try await session.upload(for: request, fromFile: item.file.url)
                guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
                if http.statusCode == 401 {
                    isConnected = false
                    throw UploadError.rejected(status: 401, detail: "Connection key rejected. Reconnect from AthleteOS.")
                }
                guard (200..<300).contains(http.statusCode), responseIsOk(responseData) else {
                    throw UploadError.rejected(status: http.statusCode, detail: responseDetail(responseData))
                }

                let responseJSON = try Self.jsonObject(responseData)
                guard
                    let fileJSON = responseJSON["file"] as? [String: Any],
                    fileJSON["verified"] as? Bool == true,
                    (fileJSON["name"] as? String) == item.file.fileName,
                    (fileJSON["sha256"] as? String)?.lowercased() == item.sha256,
                    Self.uint64(fileJSON["bytes"]) == item.byteCount
                else {
                    throw UploadError.rejected(
                        status: http.statusCode,
                        detail: "AthleteOS did not verify \(item.file.fileName). The local raw file was retained."
                    )
                }

                // Do not authorize local cleanup if a file changed during transfer.
                let after = try Data(contentsOf: item.file.url, options: [.mappedIfSafe])
                guard UInt64(after.count) == item.byteCount, Self.sha256Hex(after) == item.sha256 else {
                    throw UploadError.rejected(
                        status: http.statusCode,
                        detail: "\(item.file.fileName) changed during upload. The capture was retained."
                    )
                }
            }

            let finalize: [String: Any] = [
                "action": "finalize",
                "client_capture_id": archive.captureId.uuidString.lowercased(),
                "archive_sha256": archiveSHA,
            ]
            let finalizeData = try JSONSerialization.data(withJSONObject: finalize, options: [.sortedKeys])
            let finalizeResponse = try await sendResearchJSON(finalizeData, token: token)

            guard let receipt = Self.researchReceipt(
                finalizeResponse,
                expectedClientCaptureId: archive.captureId,
                expectedArchiveSHA: archiveSHA,
                expectedFileCount: prepared.count,
                expectedTotalBytes: totalBytes,
                requireVerified: true
            ) else {
                throw UploadError.rejected(
                    status: 200,
                    detail: "AthleteOS did not verify every raw stream file. The iPhone copy was retained."
                )
            }

            isConnected = true
            statusText = "Raw ECG and motion archived and verified in AthleteOS."
            return receipt
        } catch {
            statusText = "Raw stream archive failed: \(friendly(error)). Local raw data is retained."
            lastError = statusText
            return nil
        }
    }

    private func sendResearchJSON(_ body: Data, token: String) async throws -> Data {
        var request = URLRequest(url: researchEndpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-AthleteOS-Ingest-Token")

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        if http.statusCode == 401 {
            isConnected = false
            throw UploadError.rejected(status: 401, detail: "Connection key rejected. Reconnect from AthleteOS.")
        }
        guard (200..<300).contains(http.statusCode), responseIsOk(data) else {
            throw UploadError.rejected(status: http.statusCode, detail: responseDetail(data))
        }
        return data
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UploadError.invalidResponse
        }
        return object
    }

    private static func researchReceipt(
        _ data: Data,
        expectedClientCaptureId: UUID,
        expectedArchiveSHA: String,
        expectedFileCount: Int,
        expectedTotalBytes: UInt64,
        requireVerified: Bool
    ) -> VerifiedResearchArchiveReceipt? {
        guard
            let root = try? jsonObject(data),
            let archive = root["archive"] as? [String: Any],
            (!requireVerified || archive["verified"] as? Bool == true),
            let serverId = archive["capture_id"] as? String,
            let clientIdString = archive["client_capture_id"] as? String,
            let clientId = UUID(uuidString: clientIdString),
            clientId == expectedClientCaptureId,
            let sha = archive["archive_sha256"] as? String,
            sha.lowercased() == expectedArchiveSHA.lowercased(),
            let count = int(archive["file_count"]),
            count == expectedFileCount,
            let bytes = uint64(archive["total_bytes"]),
            bytes == expectedTotalBytes
        else { return nil }

        return VerifiedResearchArchiveReceipt(
            serverCaptureId: serverId,
            clientCaptureId: clientId,
            archiveSHA256: sha.lowercased(),
            fileCount: count,
            totalBytes: bytes
        )
    }

    private static func canonicalResearchArchiveSHA(_ files: [PreparedResearchFile]) -> String {
        let canonical = files
            .sorted { $0.file.fileName < $1.file.fileName }
            .map { "\($0.file.fileName)\t\($0.byteCount)\t\($0.sha256)\n" }
            .joined()
        return sha256Hex(Data(canonical.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let s = value as? String { return UInt64(s) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    func reportLocalCleanupError(_ error: Error) {
        lastError = "Local cleanup needs retry: \(error.localizedDescription). Raw data is retained on the iPhone or in the verified AthleteOS archive."
        statusText = lastError ?? "Local cleanup needs retry."
    }

    private func responseIsOk(_ data: Data) -> Bool {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ok = json["ok"] as? Bool
        else { return false }
        return ok
    }

    private func responseDetail(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Unexpected AthleteOS response."
        }
        return (json["detail"] as? String)
            ?? (json["error"] as? String)
            ?? "AthleteOS did not confirm the request."
    }

    private func friendly(_ error: Error) -> String {
        if let upload = error as? UploadError {
            switch upload {
            case .invalidResponse:
                return "Invalid server response."
            case let .rejected(_, detail):
                return detail
            }
        }
        return error.localizedDescription
    }

    private enum UploadError: Error {
        case invalidResponse
        case rejected(status: Int, detail: String)
    }

    private func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func readToken() -> String? {
        if let tokenProvider { return tokenProvider() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
