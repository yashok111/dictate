import Foundation
import TranscriptKit
import CryptoKit

func tinyModelCatalog() throws -> ModelCatalog {
    var catalog = try ModelCatalog.load(from: URL(fileURLWithPath: "Resources/models.json"))
    for i in catalog.artifacts.indices {
        catalog.artifacts[i].downloadBytes = 3
        catalog.artifacts[i].installedBytes = 3
        catalog.artifacts[i].downloadSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        catalog.artifacts[i].installedSHA256 = catalog.artifacts[i].downloadSHA256
        catalog.artifacts[i].archiveMember = nil
        catalog.artifacts[i].bundleFiles = nil
    }
    return catalog
}

struct ModelStoreTests {
    func testStartupRemovesOnlyOrphanStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let orphan = staging.appendingPathComponent("orphan.download")
        let directory = staging.appendingPathComponent(UUID().uuidString)
        try Data("discard me".utf8).write(to: orphan)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: directory.appendingPathComponent("model"))
        let resume = staging.appendingPathComponent("silero.resume")
        try Data("keep resume".utf8).write(to: resume)
        let store = try ModelStore(root: root, catalog: tinyModelCatalog())
        try await store.reconcile()
        try modelCheck(!FileManager.default.fileExists(atPath: orphan.path), "Crash download remained on disk")
        try modelCheck(!FileManager.default.fileExists(atPath: directory.path), "Crash extraction remained on disk")
        try modelCheck(try Data(contentsOf: resume) == Data("keep resume".utf8), "Valid resume metadata was discarded")
    }

    func testNoSpaceAndArchiveMembers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = try tinyModelCatalog()
        let noSpace = try ModelStore(root: root.appendingPathComponent("no-space"), catalog: catalog, availableSpace: { _ in 0 })
        do { try await noSpace.preflight(artifactID: "turbo-q5"); throw ModelTestFailure(description: "Accepted disk full") }
        catch is ModelError {}
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let member = source.appendingPathComponent("model")
        try Data("abc".utf8).write(to: member)
        for mode in ["regular", "link", "duplicate", "oversized", "missing"] {
            if mode == "link" {
                try FileManager.default.removeItem(at: member)
                try FileManager.default.createSymbolicLink(at: member, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
            } else if mode == "duplicate" {
                try FileManager.default.removeItem(at: member)
                try Data("abc".utf8).write(to: member)
            } else if mode == "oversized" { try Data("abcdef".utf8).write(to: member) }
            let archive = root.appendingPathComponent(mode + ".tar")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-cf", archive.path, "-C", source.path, "model"] + (mode == "duplicate" ? ["model"] : [])
            try process.run(); process.waitUntilExit()
            try modelCheck(process.terminationStatus == 0, "Create archive fixture")
            let data = try Data(contentsOf: archive)
            catalog.artifacts[0].archiveMember = mode == "missing" ? "absent" : "model"
            catalog.artifacts[0].downloadBytes = Int64(data.count)
            catalog.artifacts[0].downloadSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let store = try ModelStore(root: root.appendingPathComponent(mode), catalog: catalog)
            do {
                try await store.install(stagedDownload: archive, artifactID: "turbo-q5")
                try modelCheck(mode == "regular", "Accepted unsafe or invalid member: \(mode)")
            } catch {
                if mode == "regular" { throw error }
                try modelCheck(error is ModelError, "Expected model rejection")
            }
        }
    }

    func testVerifiedPublicationAndLeases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tinyModelCatalog()
        let store = try ModelStore(root: root, catalog: catalog)
        try await store.reconcile()
        for artifact in catalog.artifacts {
            let download = root.appendingPathComponent(UUID().uuidString)
            try Data("abc".utf8).write(to: download)
            try await store.install(stagedDownload: download, artifactID: artifact.id)
        }
        let lease = try await store.acquire(profileID: "quality")
        try modelCheck(try Data(contentsOf: URL(fileURLWithPath: lease.profile.path)) == Data("abc".utf8), "Lease points at verified data")
        do { try await store.remove(profileID: "quality"); throw ModelTestFailure(description: "Deleted an active model") }
        catch is ModelError {}
        await store.release(lease.id)
        try await store.remove(profileID: "quality")
        let ids = await store.installedArtifactIDs()
        try modelCheck(!ids.contains("turbo-q5") && ids.contains("community-1"), "Shared files survive full model installation")
        let full = try await store.acquire(profileID: "large-v3")
        await store.release(full.id)
    }

    func testCorruptFilesAndStoreLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tinyModelCatalog()
        let store = try ModelStore(root: root, catalog: catalog)
        try modelThrows { _ = try ModelStore(root: root, catalog: catalog) }
        let bad = root.appendingPathComponent("bad")
        try Data("xyz".utf8).write(to: bad)
        do { try await store.install(stagedDownload: bad, artifactID: "turbo-q5"); throw ModelTestFailure(description: "Accepted wrong digest") }
        catch is ModelError {}
        let ids = await store.installedArtifactIDs()
        try modelCheck(ids.isEmpty, "Corrupt file became ready")
    }

    func testReconcileAfterLostReceiptAndChangedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try tinyModelCatalog()
        let store = try ModelStore(root: root, catalog: catalog)
        let file = root.appendingPathComponent("download")
        try Data("abc".utf8).write(to: file)
        try await store.install(stagedDownload: file, artifactID: "turbo-q5")
        try FileManager.default.removeItem(at: root.appendingPathComponent("receipts.json"))
        try await store.reconcile()
        var ids = await store.installedArtifactIDs()
        try modelCheck(ids.contains("turbo-q5"), "A complete rename without receipt should recover")
        let installed = store.artifactURL("turbo-q5")!
        try Data("xyz".utf8).write(to: installed)
        try await store.reconcile()
        ids = await store.installedArtifactIDs()
        try modelCheck(!ids.contains("turbo-q5"), "Changed model must be reverified")
    }
}
