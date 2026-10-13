import Foundation
import TranscriptKit
import CryptoKit

struct ModelBundleTests {
    func testCompleteStagingResumesPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var catalog = try tinyModelCatalog()
        let leaf = ModelBundleFile(path:"weights.bin",url:URL(string:"https://example.com/weights")!,bytes:3,
            sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        catalog.artifacts[0].bundleFiles = [leaf]
        catalog.artifacts[0].downloadSHA256 = ModelBundleFile.manifestDigest([leaf])
        catalog.artifacts[0].installedSHA256 = catalog.artifacts[0].downloadSHA256
        let store = try ModelStore(root:root,catalog:catalog)
        let source = root.appendingPathComponent("source"); try Data("abc".utf8).write(to:source)
        for artifact in catalog.artifacts.dropFirst() { try await store.install(stagedDownload:source,artifactID:artifact.id) }
        let parent = store.artifactURL(catalog.artifacts[0].id)!.deletingLastPathComponent()
        try Data("blocks publication".utf8).write(to:parent)
        do { try await store.installBundleLeaf(stagedDownload:source,artifactID:catalog.artifacts[0].id,index:0)
             throw ModelTestFailure(description:"Publication should fail") } catch is ModelError {}
        try FileManager.default.removeItem(at:parent)
        let downloader = ModelDownloader(catalog:catalog,store:store)
        try await downloader.install(profileID:"quality")
        let installed = await store.installedArtifactIDs()
        try modelCheck(installed.contains(catalog.artifacts[0].id),"Resume skipped every leaf without publishing bundle")
    }
    func testBundlePublicationAndCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = try tinyModelCatalog()
        let leaf = ModelBundleFile(path: "Segmentation.mlmodelc/weights.bin", url: URL(string:"https://example.com/weights")!, bytes:3,
            sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        catalog.artifacts[0].bundleFiles = [leaf]
        catalog.artifacts[0].downloadSHA256 = ModelBundleFile.manifestDigest([leaf])
        catalog.artifacts[0].installedSHA256 = catalog.artifacts[0].downloadSHA256
        let store = try ModelStore(root: root, catalog: catalog)
        let source = root.appendingPathComponent("source")
        try Data("abc".utf8).write(to: source)
        try await store.installBundleLeaf(stagedDownload: source, artifactID: catalog.artifacts[0].id, index:0)
        let ready = await store.installedArtifactIDs()
        try modelCheck(ready.contains(catalog.artifacts[0].id), "Complete bundle unavailable")
        let installed = store.artifactURL(catalog.artifacts[0].id)!.appendingPathComponent(leaf.path)
        let oldDate = try FileManager.default.attributesOfItem(atPath: installed.path)[.modificationDate]!
        try Data("xyz".utf8).write(to: installed)
        try FileManager.default.setAttributes([.modificationDate:oldDate], ofItemAtPath: installed.path)
        let damaged = await store.installedArtifactIDs()
        try modelCheck(!damaged.contains(catalog.artifacts[0].id), "Nested tampering remained ready")
        catalog.artifacts[0].bundleFiles![0].path = "../outside"
        try modelThrows { try catalog.validate() }
        catalog.artifacts[0].bundleFiles = [leaf, leaf]
        try modelThrows { try catalog.validate() }
    }
}
