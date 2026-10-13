import Foundation
import Combine
import TranscriptKit

@MainActor
final class ModelsController: ObservableObject {
    let store: ModelStore
    let catalog: ModelCatalog
    let manifestURL: URL
    let downloader: ModelDownloader
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var revision = 0
    @Published private(set) var snapshot = ModelDownloadSnapshot()
    @Published private(set) var prepared = false
    @Published var error: String?
    @Published var inUse: Set<String> = []
    private var observation: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var stopped = false

    init(root: URL, catalog: ModelCatalog, manifestURL: URL? = nil) throws {
        self.manifestURL = manifestURL ?? Bundle.main.resourceURL!.appendingPathComponent("community-1.lock.json")
        self.catalog = catalog
        store = try ModelStore(root: root, catalog: catalog)
        downloader = ModelDownloader(catalog: catalog, store: store)
    }

    var profiles: [ModelProfile] {
        catalog.profiles.map { profile in
            ModelProfile(id: profile.id, title: profile.title,
                path: store.artifactURL(profile.asrArtifactID)!.path,
                peakBytes: profile.peakBytes, rank: profile.rank, automatic: profile.automatic)
        }
    }

    var configuration: RuntimeConfiguration {
        RuntimeConfiguration(vad: store.artifactURL("silero")?.path,
            diarizationModelDirectory: store.artifactURL("community-1")!.path,
            diarizationManifest: manifestURL.path, profiles: profiles,
            alignmentModel: store.artifactURL("alignment-ru")?.path)
    }

    var readyProfileIDs: Set<String> {
        Set(catalog.profiles.filter { Set($0.requiredArtifactIDs).isSubset(of: installed) }.map(\.id))
    }
    var isBusy: Bool { [.downloading, .verifying, .installing].contains(snapshot.phase) }
    func downloadBytes(for profileID: String) -> Int64 {
        ((try? catalog.requiredArtifacts(for: profileID)) ?? []).filter { !installed.contains($0.id) }.reduce(0) { $0 + $1.downloadBytes }
    }
    func installedBytes(for profileID: String) -> Int64 {
        ((try? catalog.requiredArtifacts(for: profileID)) ?? []).reduce(0) { $0 + $1.installedBytes }
    }

    func prepare() async {
        if prepared || stopped { return }
        if let preparation { await preparation.value; return }
        let task = Task { [self] in
            do { try await store.reconcile(); await downloader.restore(); await refresh() }
            catch { self.error = error.localizedDescription }
            prepared = true
        }
        preparation = task
        await task.value
        preparation = nil
        guard !stopped, observation == nil else { return }
        observation = Task { [weak self, downloader] in
            for await snapshot in await downloader.updates() {
                guard !Task.isCancelled, let self else { return }
                self.snapshot = snapshot
                await self.refresh()
            }
        }
    }

    func refresh() async {
        let next = await store.installedArtifactIDs()
        if next != installed { installed = next; revision += 1 }
    }

    func install(profileID: String) {
        guard prepared, !stopped else { return }
        error = nil
        Task {
            do { try await downloader.install(profileID: profileID) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
            await refresh()
        }
    }
    func pause() { Task { await downloader.pause() } }
    func resume(profileID: String) { install(profileID: profileID) }
    func discard(profileID: String) {
        Task {
            do { try await downloader.discard(profileID: profileID) }
            catch { self.error = error.localizedDescription }
            await refresh()
        }
    }
    func remove(profileID: String) {
        guard !isBusy else { return }
        Task {
            do { try await store.remove(profileID: profileID) }
            catch { self.error = error.localizedDescription }
            await refresh()
        }
    }
    func shutdown() async {
        stopped = true
        await downloader.shutdown()
        observation?.cancel(); observation = nil
    }
}
