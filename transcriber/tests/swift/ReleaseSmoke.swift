import Foundation
import TranscriptKit

@main
struct ReleaseSmoke {
    @MainActor
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4 else { throw ModelError("Expected APP ROOT AUDIO") }
            let app = URL(fileURLWithPath: arguments[1])
            let root = URL(fileURLWithPath: arguments[2])
            let resources = app.appendingPathComponent("Contents/Resources")
            let catalog = try ModelCatalog.load(from: resources.appendingPathComponent("models.json"))
            let models = try ModelsController(root: root.appendingPathComponent("Models"), catalog: catalog, manifestURL: resources.appendingPathComponent("community-1.lock.json"))
            await models.prepare()
            let progress = Task {
                var previous: Int64 = -50_000_000
                var artifact: String?
                for await snapshot in await models.downloader.updates() {
                    if snapshot.artifactID != artifact { artifact = snapshot.artifactID; previous = -50_000_000 }
                    if snapshot.received - previous >= 50_000_000 || snapshot.phase != .downloading {
                        print("DOWNLOAD \(snapshot.artifactID ?? "-") \(snapshot.phase.rawValue) \(snapshot.received)")
                        fflush(stdout); previous = snapshot.received
                    }
                }
            }
            try await models.downloader.install(profileID: "quality")
            progress.cancel()
            await models.refresh()
            guard models.readyProfileIDs.contains("quality") else { throw ModelError("Downloaded profile not ready") }
            let suite = "release-smoke-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let library = LibraryController(libraryRoot: root.appendingPathComponent("Library"),
                resources: resources, defaults: defaults, models: models,
                helper: app.appendingPathComponent("Contents/Helpers/transcriber-worker"))
            library.preference = "quality"
            let previousIDs = Set(library.recordings.map(\.id))
            library.importFiles([URL(fileURLWithPath: arguments[3])])
            for _ in 0..<6000 {
                if let record = library.recordings.first, !previousIDs.contains(record.id) {
                    if record.state == .failed || record.state == .waitingForMemory { throw ModelError(record.error ?? "Insufficient processing memory") }
                    if record.state == .ready { break }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let record = library.recordings.first, record.state == .ready, let transcript = record.transcript,
                  !previousIDs.contains(record.id),
                  !transcript.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelError("Release worker did not produce a transcript")
            }
            try Data(transcript.plainText.utf8).write(to: root.appendingPathComponent("transcript.txt"))
            library.shutdown(); await models.shutdown()
            let reopened = try LibraryStore(root: root.appendingPathComponent("Library")).load()
            guard reopened.first?.transcript?.plainText == transcript.plainText else { throw ModelError("Transcript did not survive reopening") }
            print("PASS release: real verified downloads, relocated worker inference, saved transcript reopens")
            print("Artifacts: \(root.path)")
            exit(0)
        } catch {
            fputs("FAIL release: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
