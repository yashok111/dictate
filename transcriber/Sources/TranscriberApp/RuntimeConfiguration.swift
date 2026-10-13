import Foundation
import TranscriptKit

struct RuntimeConfiguration: Decodable {
    let vad: String?
    let diarizationModelDirectory: String
    let diarizationManifest: String
    let profiles: [ModelProfile]
    var alignmentModel: String? = nil

    static func isManaged(_ resources: URL?) -> Bool {
        guard let resources, let data = try? Data(contentsOf: resources.appendingPathComponent("runtime.json")),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return header["mode"] as? String == "managed"
    }
}
