import Foundation

public final class LibraryStore {
    public let root: URL
    private let manager = FileManager.default
    public init(root: URL) throws {
        self.root = root
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    }
    public func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func validate(_ record: Recording) throws {
        guard !record.sourceName.isEmpty, record.sourceName != ".", record.sourceName != "..",
              !record.sourceName.contains("/"), !record.sourceName.contains("\0") else { throw TranscriptError.unsafePath }
        try record.transcript?.validate()
        _ = try MeetingContext.validated(record.meetingContext)
    }
    public func source(_ record: Recording) throws -> URL {
        try validate(record)
        return directory(record.id).appendingPathComponent(record.sourceName)
    }
    public func importFile(at source: URL, title: String? = nil, meetingContext: String? = nil) throws -> Recording {
        let context = try MeetingContext.validated(meetingContext)
        let resolved = source.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Выберите обычный аудио- или видеофайл."
            ])
        }
        var record = Recording(title: title ?? source.deletingPathExtension().lastPathComponent,
                               sourceName: "source.\(source.pathExtension)")
        record.meetingContext = context
        let folder = directory(record.id)
        let destination = try self.source(record)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        do {
            try manager.copyItem(at: resolved, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try save(record)
            return record
        } catch {
            // This directory belongs only to this unpublished import. Never
            // leave an invisible media copy after a failed copy or metadata save.
            try? manager.removeItem(at: folder)
            throw error
        }
    }
    public func delete(_ id: UUID) throws {
        let folder = directory(id)
        do { _ = try manager.attributesOfItem(atPath: folder.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        // Move the entire private record, never paths supplied by its metadata.
        // Trash also preserves the contents if the user needs to undo in Finder.
        try manager.trashItem(at: folder, resultingItemURL: nil)
    }
    public func save(_ record: Recording) throws {
        try validate(record)
        let dir = directory(record.id)
        try manager.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = dir.appendingPathComponent("recording.json")
        try encoder.encode(record).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func load(onIssue: (UUID, Error) -> Void = { _, _ in }) throws -> [Recording] {
        var records: [Recording] = []
        for dir in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let file = dir.appendingPathComponent("recording.json")
            guard manager.fileExists(atPath: file.path) else { continue }
            do {
                var record = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: file))
                guard record.id == id else { throw TranscriptError.invalidDocument }
                try validate(record)
                if record.state == .processing { record.state = .interrupted; try save(record) }
                if [.interrupted, .cancelled, .failed, .ready].contains(record.state) {
                    for attempt in try manager.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
                        where UUID(uuidString:attempt.lastPathComponent) != nil {
                        let attributes = try manager.attributesOfItem(atPath:attempt.path)
                        if attributes[.type] as? FileAttributeType == .typeDirectory { TranscriptionPipeline.cleanup(attempt) }
                    }
                }
                records.append(record)
            } catch {
                // Preserve the original files for recovery, and keep the rest of
                // the library usable when one record is unreadable.
                onIssue(id, error)
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }
}
