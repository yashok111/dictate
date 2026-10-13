import Foundation
import TranscriptKit

struct ModelsControllerTests {
    @MainActor
    func testFirstRunDoesNotDownloadAndShowsRequiredBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = try ModelsController(root: root, catalog: tinyModelCatalog())
        await models.prepare()
        try modelCheck(models.readyProfileIDs.isEmpty && !models.isBusy, "First launch must wait for user action")
        try modelCheck(models.downloadBytes(for: "quality") == 12, "Download size includes shared models")
        try modelCheck(models.installedBytes(for: "quality") == 12, "Disk size includes shared models")
        try modelCheck(models.profiles.first(where: { $0.id == "large-v3" })?.automatic == false, "Full stays opt-in")
        let snapshot = await models.downloader.snapshot()
        try modelCheck(snapshot.phase == .absent, "Opening model UI must not begin transfer")
        await models.shutdown()
    }
}
