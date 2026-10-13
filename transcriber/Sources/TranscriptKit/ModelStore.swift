import Foundation
import Darwin

public struct ModelLease {
    public let id: UUID
    public let profile: ModelProfile
    public let vad: URL
    public let diarizationModelDirectory: URL
}

private struct ModelReceipt: Codable, Equatable {
    let digest: String
    let bytes: Int64
    let modified: Date
    let inode: UInt64

    init(url: URL, digest: String) throws {
        let attributes = try ModelFileInstaller.regularFile(url)
        guard let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let bytes = attributes[.size] as? NSNumber else { throw ModelError("Не удалось проверить файл модели.") }
        self.digest = digest; self.bytes = bytes.int64Value
        self.modified = modified; self.inode = inode.uint64Value
    }
}

public actor ModelStore {
    public nonisolated let root: URL
    public nonisolated let stagingDirectory: URL
    public nonisolated let catalog: ModelCatalog
    private let lockFD: Int32
    private let availableSpace: @Sendable (URL) throws -> Int64
    private var receipts: [String: ModelReceipt] = [:]
    private var leases: [UUID: String] = [:]
    private var installing: Set<String> = []
    private var reconciling = false

    public init(root: URL, catalog: ModelCatalog,
                availableSpace: @escaping @Sendable (URL) throws -> Int64 = { try ModelStore.freeSpace($0) }) throws {
        try catalog.validate()
        self.root = root; self.catalog = catalog; self.availableSpace = availableSpace
        stagingDirectory = root.appendingPathComponent(".staging", isDirectory: true)
        try Self.privateDirectory(root)
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ModelError("Не удалось открыть хранилище моделей.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ModelError("Модели уже используются другим экземпляром Transcriber. Закройте его и повторите запуск.")
        }
        do {
            try Self.privateDirectory(stagingDirectory)
            // With the root lock held and before the store escapes its initializer,
            // no live transfer can own these leftovers from a previous process.
            for item in try FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
                if item.pathExtension == "download" || UUID(uuidString: item.lastPathComponent) != nil {
                    try FileManager.default.removeItem(at: item)
                }
            }
        }
        catch { close(fd); throw error }
        lockFD = fd
    }

    deinit { close(lockFD) }

    public nonisolated static func freeSpace(_ root: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let value = attributes[.systemFreeSize] as? NSNumber else { throw ModelError("Не удалось проверить свободное место.") }
        return value.int64Value
    }

    private nonisolated static func privateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ModelError("Путь хранилища моделей занят другим файлом.")
            }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public nonisolated func artifactURL(_ id: String) -> URL? {
        guard let artifact = catalog.artifacts.first(where: { $0.id == id }) else { return nil }
        return root.appendingPathComponent("\(artifact.id)-\(artifact.installedSHA256)", isDirectory: true)
            .appendingPathComponent(artifact.filename)
    }

    public func preflight(artifactID: String) throws {
        guard let artifact = catalog.artifacts.first(where: { $0.id == artifactID }) else { throw ModelError("Неизвестный файл модели.") }
        // Conservatively reserve a complete transfer even when resume data exists:
        // URLSession may have lost its temporary file and restart the request.
        let needed = artifact.downloadBytes + artifact.installedBytes + 256 * 1024 * 1024
        guard try availableSpace(root) >= needed else {
            throw ModelError("Недостаточно места. Освободите не менее \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) и повторите загрузку.")
        }
    }

    private func saveReceipts() throws {
        let url = root.appendingPathComponent("receipts.json")
        try JSONEncoder().encode(receipts).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func bundleDirectory(_ artifact: ModelArtifact) -> URL {
        stagingDirectory.appendingPathComponent("bundle-" + artifact.id + "-" + artifact.installedSHA256)
    }
    private func verifyBundle(_ directory: URL, artifact: ModelArtifact) throws {
        guard let files = artifact.bundleFiles,
              try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ModelError("Отсутствует комплект Community-1.")
        }
        let expected = Set(files.map(\.path))
        let canonical = directory.resolvingSymlinksInPath()
        guard let entries = FileManager.default.enumerator(at:canonical,includingPropertiesForKeys:nil) else { throw ModelError("Не удалось прочитать модель.") }
        for case let path as URL in entries {
            let type = try FileManager.default.attributesOfItem(atPath:path.path)[.type] as? FileAttributeType
            if type == .typeDirectory { continue }
            let relative = path.resolvingSymlinksInPath().pathComponents.dropFirst(canonical.pathComponents.count).joined(separator:"/")
            guard type == .typeRegular, expected.contains(relative) else { throw ModelError("Посторонний файл в модели.") }
        }
        for file in files {
            var parent = directory
            for component in file.path.split(separator: "/").dropLast() {
                parent.appendPathComponent(String(component))
                guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw ModelError("Неверный каталог модели.")
                }
            }
            try ModelFileInstaller.verify(directory.appendingPathComponent(file.path), bytes: file.bytes, digest: file.sha256)
        }
    }
    public func hasBundleLeaf(artifactID: String, index: Int) -> Bool {
        guard let artifact = catalog.artifacts.first(where: { $0.id == artifactID }),
              let files = artifact.bundleFiles, files.indices.contains(index) else { return false }
        let file = files[index]
        let root = bundleDirectory(artifact)
        // Reject symlinked staging ancestors before reading a resumable leaf.
        var parent = root
        guard (try? FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType) == .typeDirectory else { return false }
        for component in file.path.split(separator: "/").dropLast() {
            parent.appendPathComponent(String(component))
            guard (try? FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType) == .typeDirectory else { return false }
        }
        do { try ModelFileInstaller.verify(root.appendingPathComponent(file.path), bytes:file.bytes, digest:file.sha256); return true }
        catch { return false }
    }
    public func installBundleLeaf(stagedDownload: URL, artifactID: String, index: Int) throws {
        guard !reconciling, let artifact = catalog.artifacts.first(where: { $0.id == artifactID }),
              let files = artifact.bundleFiles, files.indices.contains(index),
              !leases.values.contains(where: { id in catalog.profiles.first(where: { $0.id == id })?.requiredArtifactIDs.contains(artifactID) == true }) else {
            throw ModelError("Модель занята или неизвестна.")
        }
        try Task.checkCancellation()
        let file = files[index], staging = bundleDirectory(artifact)
        try ModelFileInstaller.verify(stagedDownload, bytes:file.bytes, digest:file.sha256)
        try Self.privateDirectory(staging)
        var parent = staging
        for component in file.path.split(separator: "/").dropLast() {
            parent.appendPathComponent(String(component)); try Self.privateDirectory(parent)
        }
        let target = staging.appendingPathComponent(file.path)
        let data = try Data(contentsOf: stagedDownload, options:.mappedIfSafe)
        try data.write(to:target, options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:target.path)
        if files.indices.allSatisfy({ hasBundleLeaf(artifactID:artifactID,index:$0) }) {
            try publishBundle(artifactID:artifactID)
        }
    }
    /// Also called after a resume that skipped every already-verified leaf.
    public func publishBundle(artifactID: String) throws {
        guard !reconciling, let artifact = catalog.artifacts.first(where: { $0.id == artifactID }),
              artifact.bundleFiles != nil,
              !leases.values.contains(where: { id in catalog.profiles.first(where: { $0.id == id })?.requiredArtifactIDs.contains(artifactID) == true }) else {
            throw ModelError("Модель занята или неизвестна.")
        }
        let destination = artifactURL(artifactID)!
        if (try? verifyBundle(destination,artifact:artifact)) != nil { return }
        let staging = bundleDirectory(artifact)
        try verifyBundle(staging,artifact:artifact)
        try Task.checkCancellation()
        try Self.privateDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath:destination.path) { try FileManager.default.removeItem(at:destination) }
        guard rename(staging.path,destination.path) == 0 else { throw ModelError("Не удалось установить комплект модели.") }
    }
    public func installedArtifactIDs() -> Set<String> {
        let bundles = catalog.artifacts.filter { artifact in
            guard artifact.bundleFiles != nil, let url = artifactURL(artifact.id) else { return false }
            do { try verifyBundle(url, artifact:artifact); return true } catch { return false }
        }.map(\.id)
        return Set(bundles).union(receipts.keys.filter { id in
            guard let url = artifactURL(id), let receipt = receipts[id] else { return false }
            return (try? ModelReceipt(url: url, digest: receipt.digest)) == receipt
        })
    }

    public func reconcile() async throws {
        guard installing.isEmpty, !reconciling, leases.isEmpty else { return }
        reconciling = true
        defer { reconciling = false }
        let saved = (try? JSONDecoder().decode([String: ModelReceipt].self,
            from: Data(contentsOf: root.appendingPathComponent("receipts.json")))) ?? [:]
        receipts = [:]
        for artifact in catalog.artifacts {
            guard let url = artifactURL(artifact.id),
                  let current = try? ModelReceipt(url: url, digest: artifact.installedSHA256) else { continue }
            if saved[artifact.id] != current {
                do {
                    try await Task.detached(priority: .utility) {
                        try ModelFileInstaller.verify(url, bytes: artifact.installedBytes, digest: artifact.installedSHA256)
                    }.value
                } catch { continue }
            }
            receipts[artifact.id] = current
        }
        try saveReceipts()
    }

    public func install(stagedDownload: URL, artifactID: String) async throws {
        guard !reconciling, !installing.contains(artifactID),
              let artifact = catalog.artifacts.first(where: { $0.id == artifactID }),
              let destination = artifactURL(artifactID) else { throw ModelError("Установка модели уже выполняется.") }
        if installedArtifactIDs().contains(artifactID) { return }
        guard !leases.values.contains(where: { id in
            catalog.profiles.first(where: { $0.id == id })?.requiredArtifactIDs.contains(artifactID) == true
        }) else { throw ModelError("Модель используется для распознавания.") }
        let remaining = artifact.installedBytes + 256 * 1024 * 1024
        guard try availableSpace(root) >= remaining else { throw ModelError("Недостаточно места для установки модели.") }
        installing.insert(artifactID)
        let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { installing.remove(artifactID); try? FileManager.default.removeItem(at: directory) }
        try Self.privateDirectory(directory)
        let preparation = Task.detached(priority: .utility) {
            try ModelFileInstaller.prepare(stagedDownload, artifact: artifact, directory: directory)
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        try Self.privateDirectory(destination.deletingLastPathComponent())
        // Same-volume rename publishes a complete verified file atomically.
        guard rename(prepared.path, destination.path) == 0 else { throw ModelError("Не удалось сохранить модель: \(String(cString: strerror(errno))).") }
        let receipt = try ModelReceipt(url: destination, digest: artifact.installedSHA256)
        receipts[artifactID] = receipt
        do { try saveReceipts() }
        catch { receipts.removeValue(forKey: artifactID); throw error }
    }

    public func acquire(profileID: String) throws -> ModelLease {
        guard !reconciling, let profile = catalog.profiles.first(where: { $0.id == profileID }),
              Set(profile.requiredArtifactIDs).isSubset(of: installedArtifactIDs()),
              let asr = artifactURL(profile.asrArtifactID), let vad = artifactURL("silero"),
              let diarization = artifactURL("community-1") else {
            throw ModelError("Нужна загрузка модели.")
        }
        let id = UUID(); leases[id] = profileID
        return ModelLease(id: id, profile: ModelProfile(id: profile.id, title: profile.title, path: asr.path,
            peakBytes: profile.peakBytes, rank: profile.rank, automatic: profile.automatic),
            vad: vad, diarizationModelDirectory: diarization)
    }

    public func release(_ leaseID: UUID) { leases.removeValue(forKey: leaseID) }

    public func remove(profileID: String) throws {
        guard !reconciling, installing.isEmpty, !leases.values.contains(profileID) else {
            throw ModelError("Модель сейчас используется. Дождитесь завершения обработки.")
        }
        let artifacts = try catalog.requiredArtifacts(for: profileID)
        let installed = installedArtifactIDs()
        let retained = Set(catalog.profiles.filter { $0.id != profileID && installed.contains($0.asrArtifactID) }
            .flatMap(\.requiredArtifactIDs))
        for artifact in artifacts where !retained.contains(artifact.id) {
            guard let url = artifactURL(artifact.id) else { continue }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            receipts.removeValue(forKey: artifact.id)
        }
        try saveReceipts()
    }
}
