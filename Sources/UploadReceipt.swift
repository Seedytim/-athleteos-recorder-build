import Foundation

struct VerifiedArchiveReceipt: Equatable {
    let recordingID: String
    let sha256: String
    let processingState: String?
}

// A 2xx response alone is never permission to delete a local raw file.
// The server must explicitly confirm that the exact SHA-256 payload is archived.
enum UploadReceipt {
    static func verifiedArchive(in data: Data, expectedSHA256: String) -> VerifiedArchiveReceipt? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              json["archived"] as? Bool == true,
              let archive = json["archive"] as? [String: Any],
              archive["verified"] as? Bool == true,
              let id = archive["recording_id"] as? String,
              UUID(uuidString: id) != nil,
              let sha = archive["sha256"] as? String,
              sha.caseInsensitiveCompare(expectedSHA256) == .orderedSame
        else { return nil }
        let processing = json["processing"] as? [String: Any]
        return VerifiedArchiveReceipt(
            recordingID: id,
            sha256: sha.lowercased(),
            processingState: processing?["state"] as? String
        )
    }
}
