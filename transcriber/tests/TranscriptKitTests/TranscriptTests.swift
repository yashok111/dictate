import Foundation

private struct CheckFailure: Error { let message: String }
private func expect(_ value: Bool) throws { if !value { throw CheckFailure(message: "expected true") } }
private func expectFalse(_ value: Bool) throws { try expect(!value) }
private func expectEqual<T: Equatable>(_ value: T, _ expected: T) throws {
    if value != expected { throw CheckFailure(message: "expected \(expected), got \(value)") }
}
private func expectThrows<T>(_ body: @autoclosure () throws -> T) throws {
    do { _ = try body() } catch { return }
    throw CheckFailure(message: "expected an error")
}
private func cleanTestTrash(_ ids: [UUID]) {
    guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false) else { return }
    // Only random UUIDs created by this test; never enumerate or empty Trash.
    for id in ids { try? FileManager.default.removeItem(at: trash.appendingPathComponent(id.uuidString)) }
}
@testable import TranscriptKit

/// A throwaway UserDefaults suite: a controller built on `.standard` would read the developer's
/// own saved model preference and make profile-sensitive tests pass or fail per machine (F181).
func isolatedTestDefaults() -> UserDefaults {
    let suite = "transcriber-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

struct TranscriptTests {
    @MainActor
    func testModelSelectionSurvivesRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "transcriber-test-\(UUID().uuidString)"
        let defaults = try UserDefaults(suiteName: suite).unwrap()
        defer { defaults.removePersistentDomain(forName: suite) }
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let config = """
        {"diarizationModelDirectory":"/unused","diarizationManifest":"/unused","profiles":[
          {"id":"large-v3","title":"Full","path":"/unused","peakBytes":4500000000,"rank":3,"automatic":false}]}
        """
        try Data(config.utf8).write(to: resources.appendingPathComponent("runtime.json"))
        let library = root.appendingPathComponent("library")
        let first = LibraryController(libraryRoot: library, resources: resources, defaults: defaults)
        try expectEqual(first.preference, "auto")
        first.preference = "large-v3"
        let second = LibraryController(libraryRoot: library, resources: resources, defaults: defaults)
        try expectEqual(second.preference, "large-v3")
        second.preference = "auto"
        let third = LibraryController(libraryRoot: library, resources: resources, defaults: defaults)
        try expectEqual(third.preference, "auto")
        third.preference = "removed-profile"
        let fourth = LibraryController(libraryRoot: library, resources: resources, defaults: defaults)
        try expectEqual(fourth.preference, "auto")
    }

    func testSearchHighlightsAllLiteralUnicodeMatches() throws {
        let text = "👋 Проверка, проверка API — ПРОВЕРКА."
        let ranges = TranscriptSearch.ranges(of: "проверка", in: text)
        try expectEqual(ranges.map { String(text[$0]) }, ["Проверка", "проверка", "ПРОВЕРКА"])
        try expectEqual(TranscriptSearch.ranges(of: "", in: text).count, 0)
        try expectEqual(TranscriptSearch.ranges(of: "нет", in: text).count, 0)
        let literal = "API v3.1 / v3x1 / V3.1"
        try expectEqual(TranscriptSearch.ranges(of: "v3.1", in: literal).map { String(literal[$0]) }, ["v3.1", "V3.1"])
        let combining = "cafe\u{301} CAFÉ"
        try expectEqual(TranscriptSearch.ranges(of: "café", in: combining).count, 2)
        try expectEqual(TranscriptSearch.ranges(of: "aa", in: "aaaa").count, 2)
        try expectEqual(TranscriptSearch.ranges(of: "пров", in: text).count, 3)
    }

    @MainActor
    func testLegacyNoiseFlagDoesNotBlockQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("library"))
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let model = resources.appendingPathComponent("model")
        try Data().write(to: model)
        let runtime: [String: Any] = ["diarizationModelDirectory": model.path, "diarizationManifest": model.path,
            "profiles": [["id": "quality", "title": "Turbo", "path": model.path, "peakBytes": 1, "rank": 1]]]
        try JSONSerialization.data(withJSONObject: runtime).write(to: resources.appendingPathComponent("runtime.json"))
        let worker = resources.appendingPathComponent("transcriber-worker")
        try """
        #!/bin/sh
        [ $# -eq 4 ] && [ "$1" = "--prepare" ] || exit 47
        printf '%s' '{"schemaVersion":1,"durationMS":1000,"segments":[],"speakers":{},"model":"test"}' > "$5"
        """.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        try stageTestHelpers(worker)
        var first = Recording(title: "Noise", sourceName: "source.wav")
        first.createdAt = Date(timeIntervalSinceNow: -10)
        let second = Recording(title: "Normal", sourceName: "source.wav")
        for record in [first, second] {
            try store.save(record); try Data("audio".utf8).write(to: store.source(record))
        }
        let legacyURL = store.directory(first.id).appendingPathComponent("recording.json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
        legacy["noiseReduction"] = true
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
        let controller = LibraryController(libraryRoot: store.root, resources: resources, defaults: isolatedTestDefaults())
        for _ in 0..<200 {
            if controller.recordings.first(where: { $0.id == second.id })?.state == .ready { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expectEqual(controller.recordings.first(where: { $0.id == first.id })?.state, .ready)
        try expectEqual(controller.recordings.first(where: { $0.id == second.id })?.state, .ready)
        controller.shutdown()
    }
    func testLegacyNoiseFlagPreservesTranscript() throws {
        var record = Recording(title: "Встреча · снижение шума", sourceName: "source.wav")
        record.state = .ready
        record.transcript = Transcript(durationMS: 1000, segments: [
            Segment(startMS: 0, endMS: 1000, speaker: 0, text: "Сохранённый текст", overlap: false)
        ], speakers: ["0": "Анна"], model: "old")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        legacy["noiseReduction"] = true
        let restored = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expectEqual(restored.id, record.id)
        try expectEqual(restored.title, record.title)
        try expectEqual(restored.sourceName, record.sourceName)
        try expectEqual(restored.state, .ready)
        try expectEqual(restored.transcript, record.transcript)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as! [String: Any]
        try expect(saved["noiseReduction"] == nil)
    }
    @MainActor
    func testDeleteRemovesOnlySelectedRecordingAndUpdatesSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original)
        let store = try LibraryStore(root: root.appendingPathComponent("library"))
        var first = Recording(title: "First", sourceName: "source.wav"); first.state = .ready
        var second = Recording(title: "Second", sourceName: "source.wav"); second.state = .ready
        defer { cleanTestTrash([first.id, second.id]) }
        try store.save(first); try store.save(second)
        try FileManager.default.copyItem(at: original, to: store.source(first))
        try FileManager.default.copyItem(at: original, to: store.source(second))
        let attempt = store.directory(first.id).appendingPathComponent("attempt")
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
        try Data("transcript".utf8).write(to: attempt.appendingPathComponent("transcript.json"))
        try FileManager.default.createSymbolicLink(at: attempt.appendingPathComponent("external"), withDestinationURL: original)
        let cache = store.root.appendingPathComponent(".speaker-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: cache.appendingPathComponent("turns.json"))
        let controller = LibraryController(libraryRoot: store.root, defaults: isolatedTestDefaults())
        controller.selected = first.id
        controller.delete(first.id)
        try expectEqual(controller.recordings.map(\.id), [second.id])
        try expectEqual(controller.selected, second.id)
        try expectFalse(FileManager.default.fileExists(atPath: store.directory(first.id).path))
        try expectEqual(try Data(contentsOf: original), Data("original".utf8))
        try expectEqual(try Data(contentsOf: store.source(second)), Data("original".utf8))
        try expectEqual(try Data(contentsOf: cache.appendingPathComponent("turns.json")), Data("shared".utf8))
        try expectEqual(try store.load().map(\.id), [second.id])
        controller.delete(second.id)
        try expect(controller.recordings.isEmpty)
        try expectEqual(controller.selected, nil)
        try store.delete(second.id) // An already removed directory is harmless.
    }

    @MainActor
    func testDeleteFailureKeepsRecordingAndSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LibraryStore(root: root)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                try? FileManager.default.removeItem(at: root) }
        var record = Recording(title: "Keep", sourceName: "source.wav"); record.state = .ready
        defer { cleanTestTrash([record.id]) }
        try store.save(record)
        let controller = LibraryController(libraryRoot: root, defaults: isolatedTestDefaults())
        controller.selected = record.id
        for mode in [0o500, 0o000] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: root.path)
            controller.delete(record.id)
            try expectEqual(controller.recordings.map(\.id), [record.id])
            try expectEqual(controller.selected, record.id)
            try expect(controller.error != nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try expect(FileManager.default.fileExists(atPath: store.directory(record.id).appendingPathComponent("recording.json").path))
        }
    }
    @MainActor
    func testRepeatCreatesANewRecordingWithoutOverwritingEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var original = Recording(title: "Встреча", sourceName: "source.wav")
        original.state = .ready
        original.transcript = Transcript(durationMS: 1000, segments: [
            Segment(startMS: 0, endMS: 1000, speaker: 0, text: "Исправленный текст", overlap: false)
        ], speakers: ["0": "Анна"], model: "old")
        try store.save(original)
        try Data("original audio".utf8).write(to: store.source(original))
        let controller = LibraryController(libraryRoot: root, defaults: isolatedTestDefaults())
        controller.reprocess(original)
        for _ in 0..<200 {
            if !controller.importing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expectEqual(controller.recordings.count, 2)
        let copy = try controller.recordings.first(where: { $0.id != original.id }).unwrap()
        try expectEqual(copy.title, "Встреча · повтор")
        try expectEqual(copy.transcript, nil)
        try expectEqual(try Data(contentsOf: store.source(copy)), Data("original audio".utf8))
        let preserved = try store.load().first(where: { $0.id == original.id }).unwrap()
        try expectEqual(preserved.transcript, original.transcript)
        try expectEqual(preserved.state, .ready)
    }

    @MainActor
    func testPreviewIsReadOnlyAttemptScopedAndClearedAfterCancelOrCompletion(deleteWhileRunning: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let model = resources.appendingPathComponent("model")
        try Data().write(to: model)
        var runtime: [String: Any] = ["diarizationModelDirectory": model.path, "diarizationManifest": model.path,
            "profiles": [["id": "quality", "title": "Turbo", "path": model.path, "peakBytes": 1, "rank": 1]]]
        // Exercise both old runtime files and the optional VAD argument wiring.
        if !deleteWhileRunning { runtime["vad"] = model.path }
        try JSONSerialization.data(withJSONObject: runtime).write(to: resources.appendingPathComponent("runtime.json"))
        let worker = resources.appendingPathComponent("transcriber-worker")
        // Model inference is the slow external dependency; the real controller,
        // process runner, progress pipe, files and persistence are exercised.
        let script = """
        #!/bin/sh
        [ "$1" = "--prepare" ] || exit 44
        [ -n "$4" ] || exit 45
        \(deleteWhileRunning ? "[ $# -eq 4 ] || exit 46" : "[ $# -eq 6 ] && [ \"$5\" = \"--vad-model\" ] && [ \"$6\" = \"$3\" ] || exit 46")
        printf '%s' '{"schemaVersion":1,"durationMS":1000,"segments":[{"id":"word","startMS":0,"endMS":1000,"speaker":null,"text":"Привет","overlap":false}],"speakers":{},"model":"test"}' > "$4/transcript.json.preview.json"
        printf '%s\\n' '{"stage":"preview","progress":1}'
        /bin/sleep 1
        /bin/cp "$4/transcript.json.preview.json" "$5"
        printf '%s\\n' '{"stage":"done","progress":1}'
        """
        try script.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        try stageTestHelpers(worker)
        let libraryRoot = root.appendingPathComponent("library")
        let store = try LibraryStore(root: libraryRoot)
        let record = Recording(title: "Preview", sourceName: "source.wav")
        defer { cleanTestTrash([record.id]) }
        try store.save(record)
        try Data("audio".utf8).write(to: store.source(record))
        let controller = LibraryController(libraryRoot: libraryRoot, resources: resources, defaults: isolatedTestDefaults())
        for _ in 0..<200 {
            if controller.preview(for: record.id) != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expectEqual(controller.preview(for: record.id)?.segments.first?.text, "Привет")
        try expectEqual(controller.recordings.first?.transcript, nil)
        try expectEqual(controller.recordings.first?.state, .processing)
        if deleteWhileRunning {
            controller.importFiles([try store.source(record)])
            for _ in 0..<200 {
                if !controller.importing { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let queued = try controller.recordings.first(where: { $0.id != record.id }).unwrap()
            try expectEqual(queued.state, .queued)
            controller.delete(record.id)
            try expectEqual(controller.preview(for: record.id), nil)
            for _ in 0..<400 {
                if controller.active == nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expectEqual(controller.active, nil)
            try expectEqual(controller.recordings.map(\.id), [queued.id])
            try expectEqual(controller.recordings.first?.state, .ready)
            try expectFalse(FileManager.default.fileExists(atPath: store.directory(record.id).path))
            try expectEqual(try store.load().map(\.id), [queued.id])
            return
        }
        controller.cancel(record.id)
        try expectEqual(controller.preview(for: record.id), nil)
        for _ in 0..<300 {
            if controller.active == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expectEqual(controller.recordings.first?.state, .cancelled)
        try expectEqual(controller.recordings.first?.transcript, nil)
        controller.retry(record.id)
        for _ in 0..<400 {
            if controller.active == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expectEqual(controller.recordings.first?.state, .ready)
        try expectEqual(controller.recordings.first?.transcript?.segments.first?.text, "Привет")
        try expectEqual(controller.preview(for: record.id), nil)
    }
    func testExperimentalModelRequiresExplicitSelectionAndLegacyProfilesStillWork() throws {
        let legacy = Data(#"{"id":"quality","title":"Turbo","path":"/turbo","peakBytes":3000,"rank":2}"#.utf8)
        let turbo = try JSONDecoder().decode(ModelProfile.self, from: legacy)
        let full = ModelProfile(id: "large-v3", title: "Full", path: "/large", peakBytes: 6000,
                                rank: 3, automatic: false)
        try expect(turbo.isEligible(for: "auto"))
        try expectFalse(full.isEligible(for: "auto"))
        try expect(full.isEligible(for: "large-v3"))
        try expectFalse(turbo.isEligible(for: "large-v3"))
        let restored = try JSONDecoder().decode(ModelProfile.self, from: JSONEncoder().encode(full))
        try expectFalse(restored.isEligible(for: "auto"))
    }
    @MainActor
    func testQueuedJobStartsOnRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let record = Recording(title: "Queued", sourceName: "source.wav")
        try store.save(record)
        let controller = LibraryController(libraryRoot: root, defaults: isolatedTestDefaults())
        // The test bundle has no runtime configuration: a started attempt should
        // expose that error, not leave the restored job queued forever.
        try expectEqual(controller.recordings.first?.state, .failed)
    }

    @MainActor
    func testImportAcceptsFilesWhileAnEarlierCopyIsInFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("one.wav"), b = root.appendingPathComponent("два файла.wav")
        try Data("first".utf8).write(to: a); try Data("second".utf8).write(to: b)
        let controller = LibraryController(libraryRoot: root.appendingPathComponent("library"), defaults: isolatedTestDefaults())
        controller.importFiles([a]); controller.importFiles([b])
        for _ in 0..<200 {
            if !controller.importing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expectEqual(controller.recordings.count, 2)
        let store = try LibraryStore(root: root.appendingPathComponent("library"))
        let contents = try controller.recordings.map { try String(contentsOf: store.source($0), encoding: .utf8) }
        try expectEqual(Set(contents), Set(["first", "second"]))
    }
    func testProcessCancellationIsBoundedAndPrelaunchCancelIsHonored() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = ProcessRunner()
        let start = Date()
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["20"], log: folder.appendingPathComponent("worker.log"), onProgress: { _ in }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        runner.cancel()
        do { try await task.value; throw CheckFailure(message: "cancelled process succeeded") }
        catch is CancellationError {} // A process failure is not a cancellation acknowledgement.
        try expect(Date().timeIntervalSince(start) < 8)
        let preCancelled = ProcessRunner(); preCancelled.cancel()
        do {
            try await preCancelled.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"],
                                       log: folder.appendingPathComponent("second.log"), onProgress: { _ in })
            throw CheckFailure(message: "prelaunch cancellation ignored")
        } catch is CancellationError {}
    }
    func testMemoryPolicyCallsNativeSelector() throws {
        let profiles = [ModelProfile(id: "small", title: "Small", path: "/small", peakBytes: 200, rank: 1),
                        ModelProfile(id: "large", title: "Large", path: "/large", peakBytes: 500, rank: 2)]
        try expectEqual(MemoryPolicy.choose(profiles, installed: [true, true], headroom: 600, reserve: 100, pressure: false), 1)
        try expectEqual(MemoryPolicy.choose(profiles, installed: [true, true], headroom: 599, reserve: 100, pressure: false), 0)
        try expectEqual(MemoryPolicy.choose(profiles, installed: [true, true], headroom: 600, reserve: 100, pressure: true), nil)
    }
    func testBundledProfilesFitMeasuredBudgetsAndKeepGuards() throws {
        // Use the generated shipping profiles, not duplicated model estimates.
        let data = try Data(contentsOf: URL(fileURLWithPath: "build/swift/test-bundle/Contents/Resources/runtime.json"))
        let profiles = try JSONDecoder().decode(RuntimeConfiguration.self, from: data).profiles
        let full = profiles.filter { $0.isEligible(for: "large-v3") }
        try expectEqual(full.count, 1)
        try expectEqual(MemoryPolicy.choose(full, installed: [true], headroom: 5_000_000_000, pressure: false), 0)
        try expectEqual(MemoryPolicy.choose(full, installed: [true], headroom: 4_999_999_999, pressure: false), nil)
        try expectEqual(MemoryPolicy.choose(full, installed: [true], headroom: 10_000_000_000, pressure: true), nil)
        try expectEqual(MemoryPolicy.choose(full, installed: [false], headroom: 10_000_000_000, pressure: false), nil)
        let automatic = profiles.filter { $0.isEligible(for: "auto") }
        let chosen = try MemoryPolicy.choose(automatic, installed: automatic.map { _ in true },
            headroom: 3_500_000_000, pressure: false).unwrap()
        try expectEqual(automatic[chosen].id, "quality")
        try expectEqual(MemoryPolicy.choose(automatic, installed: automatic.map { _ in true },
            headroom: 3_499_999_999, pressure: false), nil)
    }
    func testExportRetainsSpeakerEditsAndHourTimestamps() throws {
        let doc = Transcript(durationMS: 3_605_000, segments: [
            Segment(startMS: 3_601_250, endMS: 3_604_500, speaker: 2, text: "Проверим API <v2>", overlap: false)
        ], speakers: ["2": "Анна"], model: "test")
        try expectEqual(doc.srt, "1\n01:00:01,250 --> 01:00:04,500\nАнна: Проверим API &lt;v2&gt;\n\n")
        try expect(doc.plainText.contains("Анна: Проверим API <v2>"))
        try doc.validate()
    }

    func testInvalidIntervalsAndUnknownSchemaAreRejected() throws {
        var doc = Transcript(durationMS: 1000, segments: [
            Segment(startMS: 500, endMS: 400, speaker: nil, text: "Тест", overlap: false)
        ], speakers: [:], model: "test")
        try expectThrows(try doc.validate())
        doc.segments = []; doc.schemaVersion = 9
        try expectThrows(try doc.validate())
    }

    func testPersistenceKeepsEditsAndMarksRunningJobsInterruptedOnRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var record = Recording(title: "Встреча", sourceName: "source.m4a")
        record.state = .processing
        record.transcript = Transcript(durationMS: 1000, segments: [], speakers: ["0": "Борис"], model: "test")
        try store.save(record)
        let loaded = try store.load()
        try expectEqual(loaded.count, 1)
        try expectEqual(loaded[0].state, .interrupted)
        try expectEqual(loaded[0].transcript?.speakers["0"], "Борис")
        try expectEqual(try store.load()[0].id, record.id)
    }

    func testUnsafeSourceNameCannotEscapeRecordingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let record = Recording(title: "bad", sourceName: "../../outside")
        try expectThrows(try store.save(record))
    }

    func testAttemptGateRejectsLateCompletionAfterCancelOrRestart() throws {
        var gate = AttemptGate()
        let old = gate.begin()
        try expect(gate.accepts(old))
        gate.cancel()
        try expectFalse(gate.accepts(old))
        let fresh = gate.begin()
        try expectFalse(gate.accepts(old))
        try expect(gate.accepts(fresh))
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw CheckFailure(message: "unexpected nil") }
        return value
    }
}
