import Foundation
import TranscriptKit

struct ModelTestFailure: Error, CustomStringConvertible {
    let description: String
}
func modelCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ModelTestFailure(description: message) }
}
func modelThrows(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw ModelTestFailure(description: "Expected rejection")
}

struct ModelCatalogTests {
    func testCatalog() throws {
        let catalog = try ModelCatalog.load(from: URL(fileURLWithPath: "Resources/models.json"))
        try modelCheck(catalog.profiles.map(\.id) == ["quality", "turbo-fp16", "large-v3"], "Release profiles")
        let full = catalog.profiles[2]
        try modelCheck(!full.automatic && full.peakBytes == 4_500_000_000, "Full model admission")
        try modelCheck(catalog.profiles[0].peakBytes == 3_000_000_000, "Turbo admission")
        try modelCheck(catalog.artifacts.count == 6, "Shared model catalog")
        try modelCheck(try catalog.requiredArtifacts(for: "quality").reduce(Int64(0)) { $0 + $1.installedBytes } == 913_910_789, "Complete offline model set")
        try modelThrows { _ = try catalog.requiredArtifacts(for: "missing") }
    }

    func testRejectsInvalidCatalog() throws {
        let original = try Data(contentsOf: URL(fileURLWithPath: "Resources/models.json"))
        let valid = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        for field in ["filename", "downloadSHA256", "url", "downloadBytes"] {
            var broken = valid
            var artifacts = broken["artifacts"] as! [[String: Any]]
            artifacts[0][field] = ["filename": "../escaped", "downloadSHA256": "bad", "url": "http://example.com/model", "downloadBytes": -1][field]
            broken["artifacts"] = artifacts
            let bytes = try JSONSerialization.data(withJSONObject: broken)
            try modelThrows { try JSONDecoder().decode(ModelCatalog.self, from: bytes).validate() }
        }
        var broken = valid
        var artifacts = broken["artifacts"] as! [[String: Any]]
        artifacts.append(artifacts[0]); broken["artifacts"] = artifacts
        try modelThrows { try JSONDecoder().decode(ModelCatalog.self, from: JSONSerialization.data(withJSONObject: broken)).validate() }
        broken = valid
        var profiles = broken["profiles"] as! [[String: Any]]
        profiles[0]["asrArtifactID"] = "absent"; broken["profiles"] = profiles
        try modelThrows { try JSONDecoder().decode(ModelCatalog.self, from: JSONSerialization.data(withJSONObject: broken)).validate() }
    }
}
