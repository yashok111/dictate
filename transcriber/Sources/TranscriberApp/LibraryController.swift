import AppKit
import AVFoundation
import Combine
import TranscriptKit

struct MeetingContextRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    var title: String?
    var context = ""
    var retryID: UUID?
}

@MainActor
final class LibraryController: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selected: UUID?
    @Published var error: String?
    @Published var stage = ""
    @Published var progress = 0.0
    @Published var importing = false
    @Published var contextRequest: MeetingContextRequest?
    private var pendingContextRequests: [MeetingContextRequest] = []
    @Published var preference = "auto" {
        didSet {
            defaults.set(preference, forKey: Self.modelPreferenceKey)
            if preference != oldValue { startNext() }
        }
    }
    @Published var active: UUID?
    @Published private(set) var deleting: Set<UUID> = []
    @Published private var draft: Transcript?
    @Published private var editHistory: [UUID: [Transcript]] = [:]
    let player = AVPlayer()
    let config: RuntimeConfiguration?
    let models: ModelsController?
    @Published private(set) var waitingForModels = false
    private let helperURL: URL?
    private var modelObservation: AnyCancellable?
    private var admission: UUID?
    private var modelLease: ModelLease?
    private let store: LibraryStore?
    private var runner: ProcessRunner?
    private var gate = AttemptGate()
    private var pressure = false
    private var pressureSource: DispatchSourceMemoryPressure?
    private var terminationObserver: AnyCancellable?
    private var playerRecording: UUID?
    private var pendingImports: [(url: URL, title: String?, context: String?)] = []
    private var isShuttingDown = false
    private let resources: URL?
    private let defaults: UserDefaults
    private static let modelPreferenceKey = "transcriptionModel"

    init(libraryRoot: URL? = nil, resources: URL? = Bundle.main.resourceURL, defaults: UserDefaults = .standard,
         models: ModelsController? = nil, helper: URL? = nil) {
        self.resources = resources
        self.defaults = defaults
        let root = libraryRoot ?? ProcessInfo.processInfo.environment["TRANSCRIBER_LIBRARY"].map(URL.init(fileURLWithPath:)) ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate Transcriber", isDirectory: true)
        let managed = RuntimeConfiguration.isManaged(resources)
        var modelController = models
        var configurationError: String?
        if modelController == nil, managed, let resources {
            do {
                modelController = try ModelsController(root: root.appendingPathComponent("Models"),
                    catalog: ModelCatalog.load(from: resources.appendingPathComponent("models.json")))
            } catch { configurationError = error.localizedDescription }
        }
        self.models = modelController
        helperURL = helper ?? (managed ? resources?.deletingLastPathComponent().appendingPathComponent("Helpers/transcriber-worker") : resources?.appendingPathComponent("transcriber-worker"))
        config = modelController?.configuration ?? resources.map { $0.appendingPathComponent("runtime.json") }
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(RuntimeConfiguration.self, from: $0) }
        let saved = defaults.string(forKey: Self.modelPreferenceKey) ?? "auto"
        preference = saved == "auto" || config?.profiles.contains(where: { $0.id == saved }) == true ? saved : "auto"
        do {
            let storage = try LibraryStore(root: root)
            var unreadable = 0
            let loaded = try storage.load { _, _ in unreadable += 1 }
            store = storage; recordings = loaded
            if unreadable > 0 {
                self.error = "Не удалось прочитать записей: \(unreadable). Остальные записи доступны. Исходные файлы сохранены."
            }
        } catch { store = nil; self.error = error.localizedDescription }
        if let configurationError { self.error = configurationError }
        terminationObserver = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.shutdown() }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            self.pressure = !source.data.contains(.normal)
            if source.data.contains(.critical), let id = self.active {
                self.cancel(id, waitingForMemory: true)
            }
            if !self.pressure { self.startNext() }   // memory freed: queued records may fit now (F034)
        }
        source.resume(); pressureSource = source
        if let models = self.models {
            modelObservation = models.$revision.dropFirst().sink { [weak self] _ in
                Task { @MainActor in self?.startNext() }
            }
            Task { [weak self] in await models.prepare(); self?.startNext() }
        }
        startNext()
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        requestImport(panel.urls)
    }

    func requestImport(_ urls: [URL]) {
        guard !urls.isEmpty, !isShuttingDown else { return }
        pendingContextRequests.append(MeetingContextRequest(urls: urls))
        showNextContextRequest()
    }

    func showNextContextRequest() {
        guard contextRequest == nil, !pendingContextRequests.isEmpty, !isShuttingDown else { return }
        contextRequest = pendingContextRequests.removeFirst()
    }

    func requestReprocess(_ record: Recording) {
        guard active == nil, !importing, !deleting.contains(record.id), record.state == .ready,
              let store, !isShuttingDown else { return }
        do {
            pendingContextRequests.append(MeetingContextRequest(urls: [try store.source(record)],
                title: record.title + " · повтор", context: record.meetingContext ?? ""))
            showNextContextRequest()
        } catch { self.error = error.localizedDescription }
    }

    func requestRetry(_ record: Recording) {
        guard active != record.id, !deleting.contains(record.id), !isShuttingDown else { return }
        pendingContextRequests.append(MeetingContextRequest(urls: [], title: record.title,
            context: record.meetingContext ?? "", retryID: record.id))
        showNextContextRequest()
    }

    func confirmContext(_ text: String) {
        guard let request = contextRequest, !isShuttingDown else { return }
        do {
            let context = try MeetingContext.validated(text)
            if let id = request.retryID {
                guard update(id, { $0.meetingContext = context }) else { return }
                retry(id)
            } else {
                importFiles(request.urls, title: request.title, meetingContext: context)
            }
            contextRequest = nil
        } catch { self.error = error.localizedDescription }
    }

    func importFiles(_ urls: [URL], title: String? = nil, meetingContext: String? = nil) {
        guard !isShuttingDown, let store else { return }
        let context: String?
        do { context = try MeetingContext.validated(meetingContext) }
        catch { self.error = error.localizedDescription; return }
        pendingImports.append(contentsOf: urls.map { ($0, title, context) })
        guard !importing else { return }
        importing = true
        Task {
            defer { importing = false; startNext() }
            while !isShuttingDown, !pendingImports.isEmpty {
                let request = pendingImports.removeFirst()
                let url = request.url
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let record = try await Task.detached(priority: .utility) {
                        try store.importFile(at: url, title: request.title, meetingContext: request.context)
                    }.value
                    recordings.insert(record, at: 0); selected = record.id
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    @discardableResult
    private func update(_ id: UUID, _ change: (inout Recording) -> Void) -> Bool {
        guard let index = recordings.firstIndex(where: { $0.id == id }), let store else { return false }
        var next = recordings[index]; change(&next)
        do { try store.save(next); recordings[index] = next; return true }
        catch { self.error = "Не удалось сохранить изменения: \(error.localizedDescription)"; return false }
    }

    @discardableResult
    private func transition(_ id: UUID, _ change: (inout Recording) -> Void) -> Bool {
        guard update(id, change) else {
            // A failed durable transition must not leave an endlessly queued or
            // processing job. Keep machine artifacts and require an explicit retry.
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                recordings[index].state = .failed
                recordings[index].error = error
            }
            return false
        }
        return true
    }

    func retry(_ id: UUID) {
        guard active != id, !deleting.contains(id) else { return }
        guard transition(id, { $0.state = .queued; $0.error = nil }) else { return }
        startNext()
    }

    func reprocess(_ record: Recording) {
        guard active == nil, !importing, !deleting.contains(record.id), record.state == .ready, let store else { return }
        do { importFiles([try store.source(record)],
                         title: record.title + " · повтор", meetingContext: record.meetingContext) }
        catch { self.error = error.localizedDescription }
    }

    func preview(for id: UUID) -> Transcript? {
        guard active == id, recordings.first(where: { $0.id == id })?.state == .processing else { return nil }
        return draft
    }

    func cancel(_ id: UUID, waitingForMemory: Bool = false) {
        if active == id { gate.cancel(); draft = nil; runner?.cancel() }
        transition(id) { $0.state = waitingForMemory ? .waitingForMemory : .cancelled }
    }

    func delete(_ id: UUID) {
        guard !importing, !deleting.contains(id), recordings.contains(where: { $0.id == id }) else { return }
        deleting.insert(id)
        if playerRecording == id {
            player.pause(); player.replaceCurrentItem(with: nil); playerRecording = nil
        }
        if active == id {
            // finishAttempt removes the directory only after ProcessRunner has
            // observed worker exit; stale progress/completion is rejected now.
            cancel(id)
        } else {
            removeRecording(id)
            startNext()
        }
    }

    private func removeRecording(_ id: UUID) {
        defer { deleting.remove(id) }
        guard let store, let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        do {
            try store.delete(id)
            recordings.remove(at: index)
            if selected == id {
                selected = recordings.isEmpty ? nil : recordings[min(index, recordings.count - 1)].id
            }
        } catch { self.error = "Не удалось удалить расшифровку: \(error.localizedDescription)" }
    }

    func shutdown() {
        isShuttingDown = true
        admission = nil
        pendingImports.removeAll()
        gate.cancel(); runner?.cancel(); player.pause()
    }
    func forceStopWorker() { runner?.forceCancel() }

    func startNext() {
        guard !isShuttingDown, active == nil, admission == nil, let store,
              let record = recordings.last(where: { $0.state == .queued }) else { return }
        if let models { startManaged(record, store: store, models: models); return }
        guard let config, let helper = helperURL,
              FileManager.default.fileExists(atPath: helper.path),
              FileManager.default.fileExists(atPath: config.diarizationModelDirectory) else {
            transition(record.id) { $0.state = .failed; $0.error = "Набор моделей не установлен. Соберите приложение с моделями." }
            startNext()   // the head left .queued: evaluate the rest of the queue too (F034)
            return
        }
        let candidates = config.profiles.filter { $0.isEligible(for: preference) }
        let installed = candidates.map { FileManager.default.fileExists(atPath: $0.path) }
        guard installed.contains(true) else {
            transition(record.id) { $0.state = .failed; $0.error = "Модель выбранного режима не установлена." }; startNext(); return
        }
        guard let choice = MemoryPolicy.choose(candidates, installed: installed,
            headroom: MemoryPolicy.headroom(), pressure: pressure) else {
            transition(record.id) { $0.state = .waitingForMemory }; startNext(); return
        }
        let profile = candidates[choice]
        launch(record, store: store, config: config, helper: helper, profile: profile)
    }

    private func startManaged(_ record: Recording, store: LibraryStore, models: ModelsController) {
        guard models.prepared else { waitingForModels = true; return }
        guard let config, let helper = helperURL, FileManager.default.fileExists(atPath: helper.path) else {
            transition(record.id) { $0.state = .failed; $0.error = "Повреждена установка приложения. Установите Transcriber заново." }; startNext(); return
        }
        let candidates = config.profiles.filter { $0.isEligible(for: preference) }
        let installed = candidates.map { models.readyProfileIDs.contains($0.id) }
        guard installed.contains(true) else { waitingForModels = true; return }
        waitingForModels = false
        guard let choice = MemoryPolicy.choose(candidates, installed: installed, headroom: MemoryPolicy.headroom(), pressure: pressure) else {
            transition(record.id) { $0.state = .waitingForMemory }; startNext(); return
        }
        let profile = candidates[choice], token = UUID(), selectedPreference = preference
        admission = token
        Task {
            do {
                let lease = try await models.store.acquire(profileID: profile.id)
                guard admission == token, !isShuttingDown, active == nil, preference == selectedPreference,
                      recordings.contains(where: { $0.id == record.id && $0.state == .queued }), !deleting.contains(record.id) else {
                    await models.store.release(lease.id)
                    if admission == token { admission = nil; startNext() }
                    return
                }
                admission = nil; modelLease = lease; models.inUse.insert(profile.id)
                launch(record, store: store, config: config, helper: helper, profile: lease.profile)
                if active == nil {
                    modelLease = nil; models.inUse.remove(profile.id)
                    await models.store.release(lease.id)
                }
            } catch {
                if admission == token { admission = nil; waitingForModels = true; models.error = error.localizedDescription; await models.refresh() }
            }
        }
    }

    private func launch(_ record: Recording, store: LibraryStore, config: RuntimeConfiguration, helper: URL, profile: ModelProfile) {
        guard transition(record.id, { $0.state = .processing; $0.error = nil }) else { return }
        let attempt = gate.begin(); active = record.id; draft = nil; progress = 0; stage = "Подготовка записи"
        let process = ProcessRunner(); runner = process
        Task { [self] in
            let attemptDirectory = store.directory(record.id).appendingPathComponent(attempt.uuidString)
            do {
                try FileManager.default.createDirectory(at: attemptDirectory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let output = attemptDirectory.appendingPathComponent("transcript.json")
                let source = try store.source(record)
                var arguments = ["--prepare", source.path, profile.path, attemptDirectory.path]
                if let vad = config.vad { arguments += ["--vad-model", vad] }
                if let context = try MeetingContext.validated(record.meetingContext) {
                    let file = attemptDirectory.appendingPathComponent("meeting-context.txt")
                    try Data(context.utf8).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    arguments += ["--context-file", file.path]
                }
                try await TranscriptionPipeline.run(runner:process, nativeHelper:helper,
                    diarizerHelper:helper.deletingLastPathComponent().appendingPathComponent("transcriber-diarizer"),
                    prepareArguments:arguments, directory:attemptDirectory,
                    modelDirectory:config.diarizationModelDirectory, manifest:config.diarizationManifest,
                    cacheDirectory:store.root.appendingPathComponent(".speaker-cache"), alignmentModel:config.alignmentModel) { [weak self] event in
                        Task { @MainActor in
                            guard let self, self.gate.accepts(attempt) else { return }
                            if event.stage == "preview" {
                                if let data = try? Data(contentsOf: output.appendingPathExtension("preview.json")),
                                   let preview = try? JSONDecoder().decode(Transcript.self, from: data),
                                   (try? preview.validate()) != nil {
                                    self.draft = preview
                                }
                                return
                            }
                            self.stage = ["decoding": "Читаем запись", "vad": "Проверяем участки речи", "aligning": "Уточняем время слов",
                                          "speakers": "Текст готов · определяем говорящих",
                                          "transcribing": "Распознаём речь", "done": "Сохраняем результат"][event.stage] ?? "Обработка"
                            self.progress = min(1, max(0, event.progress))
                        }
                    }
                guard gate.accepts(attempt) else { finishAttempt(); return }
                let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: output))
                try transcript.validate()
                transition(record.id) { $0.transcript = transcript; $0.state = .ready }
            } catch {
                if gate.accepts(attempt) {
                    transition(record.id) { $0.state = .failed; $0.error = error.localizedDescription }
                }
            }
            finishAttempt()
        }
    }

    private func finishAttempt() {
        if let id = active, deleting.contains(id) { removeRecording(id) }
        draft = nil; active = nil; runner = nil; gate.cancel()
        if let lease = modelLease, let models {
            modelLease = nil
            Task {
                await models.store.release(lease.id)
                // A job admitted meanwhile on the same profile holds it again: removing the id now
                // would show that model as free while it transcribes (F014).
                if modelLease?.profile.id != lease.profile.id { models.inUse.remove(lease.profile.id) }
                startNext()
            }
        } else { startNext() }
    }

    func rename(_ id: UUID, speaker: String, name: String) {
        // Store what is shown: no padding, and no newline that would split an exported
        // "[00:01:02] name: text" line (F172).
        let clean = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        editTranscript(id) { if $0.speakers[speaker] != nil { $0.speakers[speaker] = clean } }
    }
    func assign(_ id: UUID, segment: String, speaker: Int?) {
        assign(id, segments: [segment], speaker: speaker, merge: false)
    }
    func assign(_ id: UUID, segments: Set<String>, speaker: Int?, merge: Bool) {
        editTranscript(id) { $0.assignSpeaker(speaker, to: segments, merge: merge) }
    }
    private func editTranscript(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard !deleting.contains(id), let record = recordings.first(where: { $0.id == id }),
              record.state == .ready, let old = record.transcript else { return }
        var next = old; change(&next)
        guard next != old else { return }
        if update(id, { $0.transcript = next }) {
            editHistory[id, default: []].append(old)
            if editHistory[id]!.count > 20 { editHistory[id]!.removeFirst() }
        }
    }
    func canUndoEdit(_ id: UUID) -> Bool { !(editHistory[id]?.isEmpty ?? true) }
    func undoEdit(_ id: UUID) {
        guard !deleting.contains(id), recordings.first(where: { $0.id == id })?.state == .ready,
              let previous = editHistory[id]?.last else { return }
        if update(id, { $0.transcript = previous }) { editHistory[id]?.removeLast() }
    }
    func play(_ record: Recording, at milliseconds: Int64? = nil) {
        guard !deleting.contains(record.id) else { return }
        do {
            if playerRecording != record.id, let store {
                player.replaceCurrentItem(with: AVPlayerItem(url: try store.source(record)))
                playerRecording = record.id
            }
            if let milliseconds {
                player.seek(to: CMTime(value: milliseconds, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        } catch { self.error = error.localizedDescription }
    }
    func export(_ record: Recording, format: String) {
        guard let transcript = record.transcript else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = record.title + "." + format
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data: Data
            if format == "json" { let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted; data = try encoder.encode(transcript) }
            else { data = Data((format == "srt" ? transcript.srt : transcript.plainText).utf8) }
            try data.write(to: destination, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}
