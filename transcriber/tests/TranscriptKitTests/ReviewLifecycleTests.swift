import Foundation
import AppKit
import TranscriptKit

private struct LifecycleFailure: Error, CustomStringConvertible {
    let description: String
}
private func requireLifecycle(_ condition: Bool, _ message: String) throws {
    if !condition { throw LifecycleFailure(description: message) }
}

@MainActor
private final class LifecycleFixture {
    let root: URL
    let store: LibraryStore
    let controller: LibraryController
    let defaults: UserDefaults
    let defaultsSuite: String

    init(workerBody: String = "") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaultsSuite = "transcriber-lifecycle-\(UUID().uuidString)"
        guard let isolatedDefaults = UserDefaults(suiteName: defaultsSuite) else {
            throw LifecycleFailure(description: "Unable to create isolated preferences")
        }
        defaults = isolatedDefaults
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let model = resources.appendingPathComponent("model")
        try Data().write(to: model)
        let runtime: [String: Any] = ["diarizationModelDirectory": model.path, "diarizationManifest": model.path,
            "profiles": [["id": "quality", "title": "Test", "path": model.path, "peakBytes": 1, "rank": 1]]]
        try JSONSerialization.data(withJSONObject: runtime).write(to: resources.appendingPathComponent("runtime.json"))
        let worker = resources.appendingPathComponent("transcriber-worker")
        try """
        #!/bin/sh
        \(workerBody)
        printf '%s' '{"schemaVersion":1,"durationMS":1000,"segments":[],"speakers":{},"model":"test"}' > "$5"
        """.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        try stageTestHelpers(worker)
        store = try LibraryStore(root: root.appendingPathComponent("library"))
        controller = LibraryController(libraryRoot: store.root, resources: resources, defaults: defaults)
    }

    func addRecord() throws -> Recording {
        let record = Recording(title: "Test", sourceName: "source.wav")
        try store.save(record)
        try Data("audio".utf8).write(to: store.source(record))
        controller.recordings.insert(record, at: 0)
        return record
    }

    func obstructSave(_ record: Recording) throws {
        let metadata = store.directory(record.id).appendingPathComponent("recording.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
    }

    func attempts(_ record: Recording) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: store.directory(record.id), includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LifecycleFailure(description: "Timed out waiting for lifecycle transition")
    }

    func cleanUp() async {
        controller.recordings.removeAll()
        controller.shutdown()
        try? await waitUntil { controller.active == nil }
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }
}

struct ReviewLifecycleTests {
    @MainActor
    func testFailedAdmissionSaveDoesNotStartWorker() async throws {
        let fixture = try LifecycleFixture()
        do {
            let record = try fixture.addRecord()
            try fixture.obstructSave(record)
            fixture.controller.startNext()
            try await Task.sleep(nanoseconds: 200_000_000)
            let attempts = try fixture.attempts(record)
            try requireLifecycle(attempts.isEmpty, "Worker launched \(attempts.count) times after failed admission save")
            try requireLifecycle(fixture.controller.active == nil, "Admission failure retained an active attempt")
            try requireLifecycle(fixture.controller.recordings.first?.state == .failed, "Storage failure must expose retry")
        } catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }

    @MainActor
    func testCompletionSaveFailureEndsProcessingWithoutRetry() async throws {
        let fixture = try LifecycleFixture(workerBody: """
        printf '%s\\n' '{"stage":"transcribing","progress":0.5}'
        /bin/sleep 0.3
        """)
        do {
            let record = try fixture.addRecord()
            fixture.controller.startNext()
            try await fixture.waitUntil { fixture.controller.progress == 0.5 }
            try fixture.obstructSave(record)
            try await fixture.waitUntil { fixture.controller.active == nil }
            try requireLifecycle(fixture.controller.recordings.first?.state == .failed,
                                 "Failed completion save left a permanently processing record")
            try requireLifecycle(try fixture.attempts(record).count == 1, "Save failure retried inference")
            let attempt = try fixture.attempts(record)[0]
            try requireLifecycle(FileManager.default.fileExists(atPath: attempt.appendingPathComponent("transcript.json").path),
                                 "Machine output should remain available after metadata save failure")
        } catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }

    @MainActor
    func testShutdownDoesNotStartQueuedWork() async throws {
        let fixture = try LifecycleFixture(workerBody: """
        printf '%s\\n' '{"stage":"transcribing","progress":0.5}'
        exec /bin/sleep 20
        """)
        do {
            _ = try fixture.addRecord()
            let next = try fixture.addRecord()
            fixture.controller.startNext()
            try await fixture.waitUntil { fixture.controller.progress == 0.5 }
            fixture.controller.shutdown()
            try await Task.sleep(nanoseconds: 300_000_000)
            try requireLifecycle(try fixture.attempts(next).isEmpty, "Shutdown launched the next queued worker")
            try requireLifecycle(fixture.controller.recordings.first(where: { $0.id == next.id })?.state == .queued,
                                 "Shutdown changed queued work")
        } catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }

    @MainActor
    func testTerminationNotificationStopsWorkerWithoutAWindow() async throws {
        let fixture = try LifecycleFixture(workerBody: """
        printf '%s\\n' '{"stage":"transcribing","progress":0.5}'
        exec /bin/sleep 20
        """)
        do {
            _ = try fixture.addRecord()
            let next = try fixture.addRecord()
            fixture.controller.startNext()
            try await fixture.waitUntil { fixture.controller.progress == 0.5 }
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            try await fixture.waitUntil { fixture.controller.active == nil }
            try requireLifecycle(try fixture.attempts(next).isEmpty, "Termination notification started queued work")
        } catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }
}
