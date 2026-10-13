import Foundation
import TranscriptKit

private final class FixtureModelTransfer: ModelTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<TransferEvent, Error>.Continuation?
    private var calls = 0
    private var receivedResume: Data?
    var starts: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var lastResume: Data? { lock.lock(); defer { lock.unlock() }; return receivedResume }
    func start(artifact: ModelArtifact, resumeData: Data?, stagingDirectory: URL) -> AsyncThrowingStream<TransferEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); self.continuation = continuation; receivedResume = resumeData; calls += 1; lock.unlock()
        }
    }
    func pause() async -> Data? { Data("resume".utf8) }
    func finish() {
        lock.lock(); let c = continuation; lock.unlock()
        c?.finish(throwing: CancellationError())
    }
    func complete(_ file: URL) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(.downloaded(file)); c?.finish()
    }
}

private final class CompletingModelTransfer: ModelTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    func start(artifact: ModelArtifact, resumeData: Data?, stagingDirectory: URL) -> AsyncThrowingStream<TransferEvent, Error> {
        lock.lock(); requests.append(artifact.id); lock.unlock()
        return AsyncThrowingStream { continuation in
            if resumeData != nil {
                continuation.finish(throwing: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
                return
            }
            do {
                let file = stagingDirectory.appendingPathComponent(UUID().uuidString)
                try Data("abc".utf8).write(to: file)
                continuation.yield(.downloaded(file)); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func pause() async -> Data? { nil }
}

private actor PauseBarrier {
    private var replies: [CheckedContinuation<Data?, Never>] = []
    func pause() async -> Data? { await withCheckedContinuation { replies.append($0) } }
    func count() -> Int { replies.count }
    func releaseAll() { let pending = replies; replies = []; for reply in pending { reply.resume(returning: nil) } }
}

private final class DelayedPauseTransfer: ModelTransfer, @unchecked Sendable {
    let barrier = PauseBarrier()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<TransferEvent, Error>.Continuation?
    var started: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
    func start(artifact: ModelArtifact, resumeData: Data?, stagingDirectory: URL) -> AsyncThrowingStream<TransferEvent, Error> {
        AsyncThrowingStream { value in lock.lock(); continuation = value; lock.unlock() }
    }
    func pause() async -> Data? { await barrier.pause() }
    func finish() { lock.lock(); let c = continuation; lock.unlock(); c?.finish(throwing: CancellationError()) }
}

struct ModelDownloadTests {
    private func savedPause(catalog: ModelCatalog, store: ModelStore) async throws {
        let transfer = FixtureModelTransfer()
        let downloader = ModelDownloader(catalog: catalog, store: store, transferFactory: { transfer })
        let installation = Task { try? await downloader.install(profileID: "quality") }
        for _ in 0..<200 {
            if transfer.starts > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await downloader.pause(); transfer.finish(); _ = await installation.value
        await downloader.shutdown()
        try modelCheck(transfer.starts == 1, "Pause fixture must start one transfer")
    }

    func testResumeBoundToSource() async throws {
        for mode in ["same", "changed-source", "changed-content", "legacy"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var catalog = try tinyModelCatalog()
            let store = try ModelStore(root: root, catalog: catalog)
            try await savedPause(catalog: catalog, store: store)
            let index = catalog.artifacts.firstIndex(where: { $0.id == "silero" })!
            if mode == "changed-source" {
                catalog.artifacts[index].url = URL(string: "https://replacement.example/silero.bin")!
            } else if mode == "changed-content" {
                catalog.artifacts[index].downloadSHA256 = String(repeating: "a", count: 64)
            } else if mode == "legacy" {
                try Data("old opaque URLSession resume".utf8).write(to: store.stagingDirectory.appendingPathComponent("silero.resume"))
            }
            let transfer = FixtureModelTransfer()
            let downloader = ModelDownloader(catalog: catalog, store: store, transferFactory: { transfer })
            let installation = Task { try? await downloader.install(profileID: "quality") }
            for _ in 0..<200 {
                if transfer.starts > 0 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let resume = transfer.lastResume
            await downloader.pause(); transfer.finish(); _ = await installation.value
            await downloader.shutdown()
            try modelCheck(transfer.starts == 1, "Restored download starts once")
            try modelCheck(resume == (mode == "same" ? Data("resume".utf8) : nil), "Resume must match current source and content: \(mode)")
        }
    }

    func testRepeatedPauseHasOneCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tinyModelCatalog(), transfer = DelayedPauseTransfer()
        let store = try ModelStore(root: root, catalog: catalog)
        let downloader = ModelDownloader(catalog: catalog, store: store, transferFactory: { transfer })
        let installation = Task { try? await downloader.install(profileID: "quality") }
        for _ in 0..<200 {
            if transfer.started { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let first = Task { await downloader.pause() }
        for _ in 0..<200 {
            if await transfer.barrier.count() > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let second = Task { await downloader.pause() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await transfer.barrier.count()
        await transfer.barrier.releaseAll(); transfer.finish()
        await first.value; await second.value; _ = await installation.value
        await downloader.shutdown()
        try modelCheck(count == 1, "Repeated pause must share the same cancellation, got \(count)")
    }

    func testSharedReuseAndInvalidResumeRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tinyModelCatalog(), transfer = CompletingModelTransfer()
        let store = try ModelStore(root: root, catalog: catalog)
        let downloader = ModelDownloader(catalog: catalog, store: store, transferFactory: { transfer })
        let resume = store.stagingDirectory.appendingPathComponent("silero.resume")
        try await savedPause(catalog: catalog, store: store)
        do { try await downloader.install(profileID: "quality"); throw ModelTestFailure(description: "Invalid resume should request retry") }
        catch is ModelError {}
        try modelCheck(transfer.ids == ["silero"], "Invalid resume must not loop")
        try modelCheck(!FileManager.default.fileExists(atPath: resume.path), "Invalid resume must be discarded")
        try await downloader.install(profileID: "quality")
        try modelCheck(transfer.ids.count == 5, "Explicit retry installs four artifacts")
        try await downloader.install(profileID: "large-v3")
        try modelCheck(transfer.ids.count == 6 && transfer.ids.last == "large-v3", "Full should reuse three shared artifacts")
        await downloader.shutdown()
        let restored = ModelDownloader(catalog: catalog, store: store, transferFactory: { transfer })
        await restored.restore()
        try await restored.install(profileID: "quality")
        try modelCheck(transfer.ids.count == 6, "Restart must reuse all verified artifacts offline")
        await restored.shutdown()
    }

    func testRealHTTPTransport() async throws {
        guard let address = ProcessInfo.processInfo.environment["TRANSCRIBER_TEST_HTTP"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["file", "redirect", "missing", "truncated", "oversized"] {
            var artifact = try tinyModelCatalog().artifacts[0]
            artifact.url = URL(string: address + "/" + path)!
            artifact.downloadBytes = path == "oversized" ? 10 : 196608
            let transfer = URLSessionModelTransfer()
            var result: Data?
            do {
                for try await event in transfer.start(artifact: artifact, resumeData: nil, stagingDirectory: root) {
                    if case .downloaded(let url) = event {
                        result = try Data(contentsOf: url)
                        try FileManager.default.removeItem(at: url)
                    }
                }
            } catch {
                if path == "file" || path == "redirect" { throw error }
            }
            if path == "file" || path == "redirect" {
                try modelCheck(result == Data(String(repeating: "abc", count: 65536).utf8), "Real URLSession payload")
            } else { try modelCheck(result == nil, "Invalid HTTP response was delivered as successful download") }
        }
        var artifact = try tinyModelCatalog().artifacts[0]
        artifact.url = URL(string: address + "/slow")!; artifact.downloadBytes = 196608
        let first = URLSessionModelTransfer()
        var resume: Data?
        do {
            for try await event in first.start(artifact: artifact, resumeData: nil, stagingDirectory: root) {
                if case .progress(let bytes, _) = event, bytes > 0 { resume = await first.pause(); break }
            }
        } catch {}
        let second = URLSessionModelTransfer()
        var received = false
        for try await event in second.start(artifact: artifact, resumeData: resume, stagingDirectory: root) {
            if case .downloaded(let url) = event {
                received = true
                try modelCheck(try Data(contentsOf: url).count == 196608, "Resume or restart must return entire file")
                try FileManager.default.removeItem(at: url)
            }
        }
        try modelCheck(received, "Resume completed")
    }

    func testInsufficientSpaceDoesNotStartTransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tinyModelCatalog()
        let store = try ModelStore(root: root, catalog: catalog, availableSpace: { _ in 0 })
        let transfer = FixtureModelTransfer()
        let downloader = ModelDownloader(catalog: catalog, store: store, transferFactory: { transfer })
        do { try await downloader.install(profileID: "quality"); throw ModelTestFailure(description: "Disk full was ignored") }
        catch is ModelError {}
        try modelCheck(transfer.starts == 0, "Transfer started before space check")
        let state = await downloader.snapshot()
        try modelCheck(state.phase == .failed, "Disk full must expose retry")
    }

    func testRepeatedInstallAndStaleCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tinyModelCatalog(), transfer = FixtureModelTransfer()
        let store = try ModelStore(root: root, catalog: catalog)
        let downloader = ModelDownloader(catalog: catalog, store: store, transferFactory: { transfer })
        let first = Task { try await downloader.install(profileID: "quality") }
        for _ in 0..<200 {
            if transfer.starts == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await downloader.install(profileID: "quality")
        try modelCheck(transfer.starts == 1, "Repeated click spawned another transfer")
        await downloader.pause()
        let file = root.appendingPathComponent("late")
        try Data("abc".utf8).write(to: file)
        transfer.complete(file)
        _ = try? await first.value
        let ids = await store.installedArtifactIDs()
        try modelCheck(ids.isEmpty, "Paused completion published a model")
        let state = await downloader.snapshot()
        try modelCheck(state.phase == .paused, "Late callback replaced pause state")
        await downloader.shutdown()
    }
}
