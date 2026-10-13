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
            // A hit counts as use: prune() ages entries by modification date.
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                  ofItemAtPath: directory.appendingPathComponent(key + ".json").path)
            return result
        } catch { return nil }
    }
    func save(_ output: TurnOutput,key: String) throws {
        try output.validate()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try atomicJSON(output,to:directory.appendingPathComponent(key + ".json"))
        prune(keeping: key)
    }

    /// The key includes the OS version, so every macOS update orphans all entries, and each
    /// recording adds up to 16 MB: keep the cache to the newest `maxEntries` and drop anything
    /// unused for `maxAgeDays` (F033). Best effort — a failure here never fails a diarization.
    static let maxEntries = 64, maxAgeDays = 90.0
    func prune(keeping key: String) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let dated = entries.filter { $0.pathExtension == "json" && $0.lastPathComponent != key + ".json" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
        let cutoff = Date().addingTimeInterval(-Self.maxAgeDays * 24 * 3600)
        for (index, entry) in dated.enumerated() where index >= Self.maxEntries - 1 || entry.1 < cutoff {
            try? FileManager.default.removeItem(at: entry.0)
        }
    }
}
