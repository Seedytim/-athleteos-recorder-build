import Foundation

// A successful HTTP response is not sufficient to release the sensor copy.
enum UploadReceipt {
    static func recordingID(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let recording = json["recording"] as? [String: Any],
              let id = recording["id"] as? String,
              UUID(uuidString: id) != nil else { return nil }
        if let status = recording["status"] as? String, status != "complete" { return nil }
        return id
    }
}
