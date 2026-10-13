import Foundation
import TranscriptKit

struct ModelQueueTests {
    @MainActor
    func testMissingModelsWaitAndReadinessStartsOnce() async throws {
        try await exerciseQueue(behavior: "ready")
    }
    @MainActor
    func testReadinessAfterShutdownDoesNotStartWorker() async throws {
        try await exerciseQueue(behavior: "shutdown")
    }
    @MainActor
    func testReadinessDoesNotBypassFailedSave() async throws {
        try await exerciseQueue(behavior: "save-failure")
    }
    @MainActor
    func testChangingToInstalledProfileWakesQueue() async throws {
        try await exerciseQueue(behavior: "switch")
    }
    @MainActor
    private func exerciseQueue(behavior: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let helper = resources.appendingPathComponent("transcriber-worker")
        try """
        #!/bin/sh
        printf '%s' '{"schemaVersion":1,"durationMS":1000,"segments":[],"speakers":{},"model":"test"}' > "$5"
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try stageTestHelpers(helper)
        let catalog = try tinyModelCatalog()
        let models = try ModelsController(root: root.appendingPathComponent("Models"), catalog: catalog)
        await models.prepare()
        let suite = "model-queue-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryController(libraryRoot: root.appendingPathComponent("library"), resources: resources,
                                        defaults: defaults, models: models, helper: helper)
        if behavior == "switch" { library.preference = "large-v3" }
        let source = root.appendingPathComponent("audio.wav")
        try Data("audio".utf8).write(to: source)
        library.importFiles([source])
        for _ in 0..<200 {
            if !library.importing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try modelCheck(library.recordings.first?.state == .queued && library.active == nil, "Missing model should wait")
        let record = library.recordings[0]
        if behavior == "shutdown" { library.shutdown() }
        if behavior == "save-failure" {
            let metadata = root.appendingPathComponent("library/\(record.id.uuidString)/recording.json")
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        }
        for artifact in try catalog.requiredArtifacts(for: "quality") {
            let file = root.appendingPathComponent(UUID().uuidString)
            try Data("abc".utf8).write(to: file)
            try await models.store.install(stagedDownload: file, artifactID: artifact.id)
        }
        await models.refresh()
        if behavior == "switch" {
            try await Task.sleep(nanoseconds: 100_000_000)
            try modelCheck(library.recordings.first?.state == .queued, "Missing full should still wait")
            library.preference = "quality"
        }
        for _ in 0..<500 {
            if library.recordings.first?.state == .ready || library.recordings.first?.state == .failed || behavior == "shutdown" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let shouldRun = behavior == "ready" || behavior == "switch"
        let expected: RecordingState = shouldRun ? .ready : behavior == "shutdown" ? .queued : .failed
        try modelCheck(library.recordings.first?.state == expected, "Readiness/\(behavior) should preserve admission gate")
        await models.refresh()
        try await Task.sleep(nanoseconds: 100_000_000)
        let attempts = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library/\(record.id.uuidString)").path)
            .filter { UUID(uuidString: $0) != nil }
        try modelCheck(attempts.count == (shouldRun ? 1 : 0), "Readiness launched unexpected work")
        library.shutdown()
        await models.shutdown()
    }
}
