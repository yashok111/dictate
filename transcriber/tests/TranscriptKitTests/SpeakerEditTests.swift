import Foundation
import TranscriptKit

private enum EditFailure: Error { case assertion }
private func checkEdit(_ value: Bool) throws { if !value { throw EditFailure.assertion } }

struct SpeakerEditTests {
    @MainActor func testBulkMergeUndoAndSaveFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var record = Recording(title: "edit", sourceName: "source.wav")
        record.state = .ready
        record.transcript = Transcript(durationMS: 8000, segments: [
            Segment(startMS: 0, endMS: 1000, speaker: 0, text: "Да,", overlap: false),
            Segment(startMS: 1100, endMS: 1500, speaker: nil, text: "это", overlap: false),
            Segment(startMS: 1600, endMS: 2200, speaker: 1, text: "так.", overlap: false),
            Segment(startMS: 2300, endMS: 2600, speaker: 0, text: "Вместе", overlap: true),
            Segment(startMS: 6000, endMS: 7000, speaker: 0, text: "Позже", overlap: false)
        ], speakers: ["0":"Один", "1":"Два"], model: "test")
        try store.save(record)
        let controller = LibraryController(libraryRoot: root, resources: nil)
        let original = record.transcript!
        let selected = Set(original.segments[1...2].map(\.id))
        controller.assign(record.id, segments: selected, speaker: 0, merge: true)
        let edited = controller.recordings.first!.transcript!
        try checkEdit(edited.segments.count == 3 && edited.segments[0].text == "Да, это так.")
        try checkEdit(edited.segments[0].startMS == 0 && edited.segments[0].endMS == 2200)
        try checkEdit(edited.segments[1].overlap && controller.canUndoEdit(record.id))
        try checkEdit(try store.load().first!.transcript == edited)
        controller.undoEdit(record.id)
        try checkEdit(controller.recordings.first!.transcript == original)
        try checkEdit(try store.load().first!.transcript == original)
        let metadata = store.directory(record.id).appendingPathComponent("recording.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        controller.assign(record.id, segments: selected, speaker: 0, merge: true)
        try checkEdit(controller.recordings.first!.transcript == original && !controller.canUndoEdit(record.id))
        try checkEdit(controller.error != nil)
    }
}
