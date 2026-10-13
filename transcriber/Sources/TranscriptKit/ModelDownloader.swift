import Foundation

public enum ModelDownloadPhase: String, Codable, Sendable {
    case absent, downloading, verifying, installing, ready, paused, failed
}

public struct ModelDownloadSnapshot: Codable, Sendable {
    public var profileID: String?
    public var artifactID: String?
    public var phase: ModelDownloadPhase = .absent
    public var received: Int64 = 0
    public var total: Int64?
    public var error: String?
    public init(profileID: String? = nil, artifactID: String? = nil, phase: ModelDownloadPhase = .absent) {
        self.profileID = profileID; self.artifactID = artifactID; self.phase = phase
    }
}

public actor ModelDownloader {
    private struct SavedResume: Codable {
        let url: URL
        let sha256: String
        let bytes: Int64
        let data: Data
    }
    private let catalog: ModelCatalog
    private let store: ModelStore
    private let transferFactory: @Sendable () -> any ModelTransfer
    private var currentArtifact: ModelArtifact?
    private var current: (any ModelTransfer)?
    private var generation = UUID()
    private var busy = false
    private var stopped = false
    private var installation: Task<Void, Error>?
    private var pauseOperation: Task<Void, Never>?
    private var state = ModelDownloadSnapshot()
    private var observers: [UUID: AsyncStream<ModelDownloadSnapshot>.Continuation] = [:]

    public init(catalog: ModelCatalog, store: ModelStore,
                transferFactory: @escaping @Sendable () -> any ModelTransfer = { URLSessionModelTransfer() }) {
        self.catalog = catalog; self.store = store; self.transferFactory = transferFactory
    }

    public func snapshot() -> ModelDownloadSnapshot { state }

    public func updates() -> AsyncStream<ModelDownloadSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish() { for observer in observers.values { observer.yield(state) } }
    private func check(_ token: UUID) throws {
        guard generation == token, !stopped else { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func resumeURL(_ id: String) -> URL { store.stagingDirectory.appendingPathComponent(id + ".resume") }
    private func loadResume(for artifact: ModelArtifact) -> Data? {
        let file = resumeURL(artifact.id)
        // URLSession's opaque data embeds a request URL. Never reuse it after a
        // source/content change, including legacy data with no source identity.
        guard let encoded = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(SavedResume.self, from: encoded),
              saved.url == artifact.url, saved.sha256 == artifact.downloadSHA256,
              saved.bytes == artifact.downloadBytes else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return saved.data
    }
    private var stateURL: URL { store.stagingDirectory.appendingPathComponent("download-state.json") }
    private func saveState() {
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch { state.error = "Не удалось сохранить состояние загрузки: \(error.localizedDescription)" }
    }
    public func restore() {
        guard !busy, let data = try? Data(contentsOf: stateURL),
              var saved = try? JSONDecoder().decode(ModelDownloadSnapshot.self, from: data),
              catalog.profiles.contains(where: { $0.id == saved.profileID }) else { return }
        if saved.phase != .ready { saved.phase = .paused }
        state = saved; publish()
    }

    public func install(profileID: String) async throws {
        guard !stopped else { throw CancellationError() }
        guard !busy else { return }
        let required = try catalog.requiredArtifacts(for: profileID)
        busy = true; let token = UUID(); generation = token
        state = ModelDownloadSnapshot(profileID: profileID, phase: .downloading)
        saveState(); publish()
        defer {
            if generation == token { busy = false; current = nil; installation = nil }
        }
        do {
            for artifact in required {
                try check(token)
                if await store.installedArtifactIDs().contains(artifact.id) { continue }
                try await store.preflight(artifactID: artifact.id)
                try check(token)
                state.artifactID = artifact.id; state.received = 0; state.total = artifact.downloadBytes
                state.phase = .downloading; state.error = nil; publish()
                let bundle = artifact.bundleFiles
                for leafIndex in 0..<(bundle?.count ?? 1) {
                if bundle != nil, await store.hasBundleLeaf(artifactID:artifact.id,index:leafIndex) { continue }
                let parentArtifact = artifact
                let artifact = bundle == nil ? artifact : artifact.leafArtifact(leafIndex)
                currentArtifact = artifact
                let resumeFile = resumeURL(artifact.id)
                var resume = loadResume(for: artifact)
                var retries = 0
                var completed = false
                while !completed {
                    try check(token)
                    let transfer = transferFactory(); current = transfer
                    do {
                        var downloaded = false
                        for try await event in transfer.start(artifact: artifact, resumeData: resume, stagingDirectory: store.stagingDirectory) {
                            // Always own/clean transferred files, even after pause.
                            if case .downloaded(let file) = event {
                                defer { try? FileManager.default.removeItem(at: file) }
                                try check(token)
                                state.phase = .verifying; publish()
                                let work = Task {
                                    if bundle != nil {
                                        try await store.installBundleLeaf(stagedDownload:file, artifactID:parentArtifact.id,index:leafIndex)
                                    } else { try await store.install(stagedDownload: file, artifactID: artifact.id) }
                                }
                                installation = work
                                try await work.value
                                try check(token)
                                downloaded = true
                            } else if case .progress(let received, let total) = event {
                                try check(token)
                                state.received = received + (bundle?.prefix(leafIndex).reduce(0) { $0 + $1.bytes } ?? 0)
                                state.total = bundle == nil ? total : parentArtifact.downloadBytes; publish()
                            }
                        }
                        try check(token)
                        guard downloaded else { throw ModelError("Загрузка прервана. Повторите попытку.") }
                        try? FileManager.default.removeItem(at: resumeFile)
                        completed = true
                    } catch {
                        try check(token)
                        let nsError = error as NSError
                        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                            try saveResume(data, for: artifact)
                        }
                        // Resume data can point at expired CDN URLs or deleted temp files.
                        // Discard unusable data; the next explicit retry uses the origin.
                        if resume != nil {
                            try? FileManager.default.removeItem(at: resumeFile)
                            throw ModelError("Не удалось продолжить загрузку. Нажмите «Повторить», чтобы скачать этот файл заново.")
                        }
                        let transient = nsError.domain == NSURLErrorDomain &&
                            [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet].contains(nsError.code)
                        guard transient, retries < 2 else { throw error }
                        retries += 1; resume = loadResume(for: artifact)
                        try await Task.sleep(nanoseconds: UInt64(retries) * 1_000_000_000)
                    }
                }
                }
                try check(token)
                if bundle != nil { try await store.publishBundle(artifactID:artifact.id) }
            }
            try check(token)
            state.phase = .ready; state.error = nil; saveState(); publish()
        } catch {
            if generation == token {
                state.phase = .failed; state.error = error.localizedDescription; saveState(); publish()
            }
            throw error
        }
    }

    private func saveResume(_ data: Data, for artifact: ModelArtifact) throws {
        let url = resumeURL(artifact.id)
        let saved = SavedResume(url: artifact.url, sha256: artifact.downloadSHA256,
                               bytes: artifact.downloadBytes, data: data)
        try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func pause() async {
        // All callers share one cancellation. Keep admission closed until the
        // owner publishes the paused state, so a late callback cannot reset a
        // newer transfer's current/busy fields.
        if let pauseOperation { await pauseOperation.value; return }
        guard busy else { return }
        generation = UUID()
        let transfer = current, work = installation, artifact = currentArtifact
        // Keep busy until cancellation has drained, preventing a new install race.
        work?.cancel()
        let operation = Task { [self] in
            if let data = await transfer?.pause(),
               let artifact {
                do { try saveResume(data, for: artifact) }
                catch { state.error = "Не удалось сохранить продолжение загрузки: \(error.localizedDescription)" }
            }
            _ = try? await work?.value
        }
        pauseOperation = operation
        await operation.value
        pauseOperation = nil
        current = nil; installation = nil; busy = false
        state.phase = .paused; saveState(); publish()
    }

    public func resume(profileID: String) async throws { try await install(profileID: profileID) }

    public func discard(profileID: String) async throws {
        if busy, state.profileID == profileID { await pause() }
        guard !busy else { throw ModelError("Дождитесь завершения другой загрузки.") }
        for artifact in try catalog.requiredArtifacts(for: profileID) {
            try? FileManager.default.removeItem(at: resumeURL(artifact.id))
        }
        state = ModelDownloadSnapshot(); saveState(); publish()
    }

    public func shutdown() async { stopped = true; await pause() }
}
