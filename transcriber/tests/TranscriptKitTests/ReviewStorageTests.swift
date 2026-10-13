import Foundation
import TranscriptKit

private struct StorageCheckFailure: Error { let message: String }
private func storageCheck(_ value: Bool, _ message: String) throws {
    if !value { throw StorageCheckFailure(message: message) }
}

struct ReviewStorageTests {
    @MainActor
    func testFailedImportLeavesNoHiddenRecordDirectory() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("unreadable.wav")
        try Data("unreadable media".utf8).write(to: source)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
        let library = root.appendingPathComponent("library")
        let controller = LibraryController(libraryRoot: library, resources: nil)
        controller.importFiles([source])
        for _ in 0..<200 {
            if !controller.importing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try storageCheck(controller.recordings.isEmpty && controller.error != nil, "failed import was accepted")
        try storageCheck(try manager.contentsOfDirectory(atPath: library.path).isEmpty,
                         "failed import left an unreachable private directory")
    }

    @MainActor
    func testImportedSymlinkRetainsMediaAfterOriginalRemoved() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let original = root.appendingPathComponent("original.wav")
        let linked = root.appendingPathComponent("linked.wav")
        let bytes = Data("owned recording".utf8)
        try bytes.write(to: original)
        try manager.createSymbolicLink(at: linked, withDestinationURL: original)
        let controller = LibraryController(libraryRoot: root.appendingPathComponent("library"), resources: nil)
        controller.importFiles([linked])
        for _ in 0..<200 {
            if !controller.importing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let record = controller.recordings.first else {
            throw StorageCheckFailure(message: "the source link was not imported")
        }
        let store = try LibraryStore(root: root.appendingPathComponent("library"))
        let savedSource = try store.source(record)
        try manager.removeItem(at: original)
        try storageCheck(try Data(contentsOf: savedSource) == bytes, "import retained a symlink instead of media")
    }

    func testCorruptRecordDoesNotHideHealthyLibrary() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var healthy = Recording(title: "Healthy", sourceName: "source.wav")
        healthy.state = .processing
        let corrupt = Recording(title: "Corrupt", sourceName: "source.wav")
        try store.save(healthy)
        try store.save(corrupt)
        let corruptFile = store.directory(corrupt.id).appendingPathComponent("recording.json")
        let damaged = Data("{".utf8)
        try damaged.write(to: corruptFile)

        var issues: [UUID] = []
        let loaded = try store.load { id, _ in issues.append(id) }
        try storageCheck(loaded.map(\.id) == [healthy.id], "a damaged record hid healthy recordings")
        try storageCheck(issues == [corrupt.id], "the unreadable recording was not reported")
        try storageCheck(loaded.first?.state == .interrupted, "interrupted recovery was lost")
        try storageCheck(try Data(contentsOf: corruptFile) == damaged, "damaged metadata was overwritten")
    }

    func testUnreadableLibraryRootStillFails() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        try manager.removeItem(at: root)
        do { _ = try store.load() }
        catch { return }
        throw StorageCheckFailure(message: "an unavailable library must not appear empty")
    }

    func testInvalidRecordIdentityAndTranscriptAreIsolated() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let healthy = Recording(title: "Healthy", sourceName: "source.wav")
        let mismatched = Recording(title: "Wrong identity", sourceName: "source.wav")
        var invalid = Recording(title: "Invalid timing", sourceName: "source.wav")
        for record in [healthy, mismatched, invalid] { try store.save(record) }
        let mismatchFile = store.directory(mismatched.id).appendingPathComponent("recording.json")
        let invalidFile = store.directory(invalid.id).appendingPathComponent("recording.json")
        try JSONEncoder().encode(healthy).write(to: mismatchFile)
        invalid.transcript = Transcript(durationMS: 1000, segments: [
            Segment(startMS: 900, endMS: 800, speaker: nil, text: "Invalid", overlap: false)
        ], speakers: [:], model: "test")
        let invalidData = try JSONEncoder().encode(invalid)
        try invalidData.write(to: invalidFile)
        var issues: [UUID] = []
        let loaded = try store.load { id, _ in issues.append(id) }
        try storageCheck(loaded.map(\.id) == [healthy.id], "invalid metadata escaped validation")
        try storageCheck(Set(issues) == Set([mismatched.id, invalid.id]), "invalid metadata was not reported")
        try storageCheck(try Data(contentsOf: invalidFile) == invalidData, "invalid transcript was overwritten")
    }
}
