import Foundation
import Combine
import Security

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

    private let endpoint = URL(string: "https://bjdpzxbfpgmzwcdgzqso.supabase.co/functions/v1/ingest-hrv-logger")!
    private let keychainService = "nz.co.athleteos.recorder"
    private let keychainAccount = "overnight-ingest-token"

    init() {
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

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UploadError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode), responseIsOk(data) else {
                throw UploadError.rejected(status: http.statusCode, detail: responseDetail(data))
            }

            try saveToken(token)
            connectionKeyDraft = ""
            isConnected = true
            statusText = "Connected to AthleteOS. Saved recordings will upload automatically."
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

    func upload(fileURL: URL) async -> Bool {
        guard !busy else { return false }
        lastError = nil
        guard let token = readToken() else {
            isConnected = false
            statusText = "Connect AthleteOS before deleting the H10 sensor copy."
            return false
        }

        busy = true
        statusText = "Uploading raw RR recording to AthleteOS…"
        defer { busy = false }

        do {
            var request = URLRequest(url: endpoint, timeoutInterval: 90)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(fileURL.lastPathComponent, forHTTPHeaderField: "X-File-Name")
            request.setValue(token, forHTTPHeaderField: "X-AthleteOS-Ingest-Token")

            let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
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

            let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
            let duplicate = json?["duplicate"] as? Bool ?? false
            if let recording = json?["recording"] as? [String: Any] {
                lastUploadedRecordingId = recording["id"] as? String
            }

            rememberUpload(fileURL)
            isConnected = true
            statusText = duplicate
                ? "AthleteOS confirmed this RR recording was already stored."
                : "AthleteOS received and processed the RR recording."
            return true
        } catch {
            statusText = "AthleteOS upload failed: \(friendly(error)). Local and H10 copies are retained."
            lastError = statusText
            return false
        }
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
