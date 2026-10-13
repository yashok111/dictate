import Foundation
struct SpeakerCache {
    let directory: URL
    static func key(input: PreparedInput, provenance: Provenance) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let metadata = ["source":input.sourceSHA256,"decode":String(input.decodeVersion),"format":input.pcmFormat,
                        "os":ProcessInfo.processInfo.operatingSystemVersionString,"provenance":String(decoding:try encoder.encode(provenance),as:UTF8.self)]
        return digest(try encoder.encode(metadata))
    }
    func load(key: String,durationMS: Int64,provenance: Provenance) -> TurnOutput? {
        do {
            let result = try JSONDecoder().decode(TurnOutput.self,from:regularData(directory.appendingPathComponent(key + ".json"),limit:16777216))
            try result.validate()
            guard result.durationMS == durationMS, result.provenance == provenance else { return nil }
            return result
        } catch { return nil }
    }
    func save(_ output: TurnOutput,key: String) throws {
        try output.validate()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try atomicJSON(output,to:directory.appendingPathComponent(key + ".json"))
    }
}
