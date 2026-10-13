import Foundation
import TranscriptKit

struct MeetingContextTests {
    func testValidation() throws {
        try modelCheck(try MeetingContext.validated(" \n ") == nil, "Blank context is absent")
        try modelCheck(try MeetingContext.validated(" C# #123 \n") == "C# #123", "Context is not a dictionary with comments")
        try modelThrows { _ = try MeetingContext.validated(String(repeating: "я", count: 301)) }
        try modelThrows { _ = try MeetingContext.validated("bad\0context") }
    }

    @MainActor
    func testImportWaitsForConfirmationAndRepeatPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("audio.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: source)
        let folder = root.appendingPathComponent("Library")
        let library = LibraryController(libraryRoot: folder, resources: nil)
        defer { library.shutdown() }
        library.requestImport([source])
        try modelCheck(library.recordings.isEmpty && !library.importing, "Opening context must not start import")
        library.contextRequest = nil
        try modelCheck(library.recordings.isEmpty, "Cancel must not create a record")
        library.requestImport([source])
        library.confirmContext("Анна, TestFlight, C#, #123")
        for _ in 0..<200 where library.importing { try await Task.sleep(nanoseconds: 10_000_000) }
        let store = try LibraryStore(root: folder)
        var original = try store.load()[0]
        try modelCheck(original.meetingContext == "Анна, TestFlight, C#, #123", "Import context must be saved")
        original.state = .ready
        original.transcript = Transcript(durationMS: 1000, segments: [], speakers: [:], model: "test")
        try store.save(original)
        library.recordings = [original]
        library.requestReprocess(original)
        try modelCheck(library.contextRequest?.context == original.meetingContext, "Repeat must prefill the context")
        library.confirmContext("Другой контекст")
        for _ in 0..<200 where library.importing { try await Task.sleep(nanoseconds: 10_000_000) }
        let loaded = try store.load()
        try modelCheck(loaded.count == 2, "Repeat makes a new record")
        try modelCheck(loaded.first(where: { $0.id == original.id })?.meetingContext == original.meetingContext, "Original context is immutable on repeat")
        try modelCheck(loaded.first(where: { $0.id != original.id })?.meetingContext == "Другой контекст", "Repeated record uses edited context")
    }

    @MainActor
    func testWorkerReceivesPrivateContextFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let model = resources.appendingPathComponent("model")
        try Data().write(to: model)
        let config: [String: Any] = ["diarizationModelDirectory": model.path, "diarizationManifest": model.path,
            "profiles": [["id": "quality", "title": "Test", "path": model.path, "peakBytes": 1, "rank": 1]]]
        try JSONSerialization.data(withJSONObject: config).write(to: resources.appendingPathComponent("runtime.json"))
        let helper = resources.appendingPathComponent("transcriber-worker")
        try """
        #!/bin/sh
        output="$5"
        shift 5
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--context-file" ]; then
            cp "$2" "${output}.context"
          fi
          shift
        done
        printf '%s' '{"schemaVersion":1,"durationMS":1000,"segments":[],"speakers":{},"model":"test"}' > "$output"
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try stageTestHelpers(helper)
        let folder = root.appendingPathComponent("Library")
        let library = LibraryController(libraryRoot: folder, resources: resources)
        defer { library.shutdown() }
        let context = "Анна Смирнова, C#, #123"
        library.importFiles([model], meetingContext: context)
        for _ in 0..<500 {
            if library.recordings.first?.state == .ready { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try modelCheck(library.recordings.first?.state == .ready, "Context worker should complete")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        guard let captured = files.first(where: { $0.lastPathComponent == "transcript.json.context" }) else {
            throw ModelTestFailure(description: "Worker did not receive the context file")
        }
        try modelCheck(try String(contentsOf: captured, encoding: .utf8) == context, "Exact context must reach the worker")
        guard let file = files.first(where: { $0.lastPathComponent == "meeting-context.txt" }) else {
            throw ModelTestFailure(description: "Missing private context file")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try modelCheck(attributes[.posixPermissions] as? Int == 0o600, "Context file must be owner-only")
    }

    func testContextSurvivesMetadataRoundTripAndLegacyRecordsLoad() throws {
        let record = Recording(title: "Встреча", sourceName: "source.wav")
        let legacy = try JSONEncoder().encode(record)
        _ = try JSONDecoder().decode(Recording.self, from: legacy)
        var json = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        let context = "Релиз. Анна Смирнова, TestFlight, C#, задача #123."
        json["meetingContext"] = context
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: json))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        try modelCheck(encoded["meetingContext"] as? String == context, "Meeting context must survive a metadata round trip")
    }
}
