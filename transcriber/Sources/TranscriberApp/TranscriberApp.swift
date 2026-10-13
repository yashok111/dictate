import SwiftUI
import AVKit
import UniformTypeIdentifiers
import TranscriptKit

// Disambiguate the property wrapper from the new SDK macro of the same name.
private typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(TranscriberApplicationDelegate.self) private var applicationDelegate
    @StateObject private var library = LibraryController()
    var body: some Scene {
        WindowGroup("Transcriber") {
            LibraryView(library: library)
                .onAppear { applicationDelegate.library = library }
                .frame(minWidth: 900, minHeight: 620)
                .alert("Не удалось выполнить действие", isPresented: Binding(
                    get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                        Button("Понятно") { library.error = nil }
                    } message: { Text(library.error ?? "") }
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Загрузить запись…") { library.openFiles() }.keyboardShortcut("o")
            }
        }
    }
}

private struct LibraryView: View {
    @ObservedObject var library: LibraryController
    @ViewState(initialValue: nil) private var deletion: Recording?
    @ViewState(initialValue: false) private var dropTargeted: Bool
    @ViewState(initialValue: false) private var showingModels: Bool
    @ViewState(initialValue: false) private var firstRun: Bool

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Расшифровки").font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Text("\(library.recordings.count)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.primary.opacity(0.05), in: Capsule())
                    }
                    Button(action: library.openFiles) {
                        Label("Загрузить запись", systemImage: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .glassControl(prominent: true).controlSize(.large).disabled(library.importing)
                    if library.importing { ProgressView("Копируем запись…").controlSize(.small) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Для новых записей").font(.system(size: 10)).foregroundStyle(.secondary)
                        Picker("Модель", selection: $library.preference) {
                            Text("Автоматически").tag("auto")
                            ForEach(library.config?.profiles ?? []) { profile in
                                Text(profile.title).tag(profile.id)
                                    .disabled(!FileManager.default.fileExists(atPath: profile.path))
                            }
                        }.labelsHidden().pickerStyle(.menu).glassControl().controlSize(.regular)
                            .disabled(library.active != nil || library.importing)
                        if library.models != nil {
                            Button("Модели…") { firstRun = false; showingModels = true }
                            if library.waitingForModels {
                                Text("Нужна загрузка модели").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(16)

                List(selection: $library.selected) {
                    ForEach(library.recordings) { record in
                        RecordingRow(record: record).tag(record.id)
                            .contextMenu {
                                Button(role: .destructive) { deletion = record } label: {
                                    Label("Удалить расшифровку…", systemImage: "trash")
                                }.disabled(library.importing || library.deleting.contains(record.id))
                            }
                    }
                }.listStyle(.sidebar)

            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            if let record = library.recordings.first(where: { $0.id == library.selected }) {
                RecordingDetail(library: library, record: record, requestDelete: { deletion = record }).id(record.id)
            } else {
                LibraryWelcomeView(hasRecordings: !library.recordings.isEmpty)
            }
        }
        .onAppear {
            if library.selected == nil { library.selected = library.recordings.first?.id }
        }
        .task {
            if let models = library.models {
                await models.prepare()
                if models.readyProfileIDs.isEmpty { firstRun = true; showingModels = true }
            }
        }
        .sheet(isPresented: $showingModels) {
            if let models = library.models { ModelsView(controller: models, firstRun: firstRun) }
        }
        .sheet(item: $library.contextRequest, onDismiss: { library.showNextContextRequest() }) { request in
            MeetingContextView(request: request, confirm: library.confirmContext)
        }
        .alert("Удалить расшифровку?", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { record in
                Button("Удалить", role: .destructive) { library.delete(record.id) }
                Button("Отмена", role: .cancel) {}
            } message: { record in
                Text("«\(record.title)» и копия аудио в приложении будут перемещены в Корзину. Исходный файл останется на месте. Если запись обрабатывается, распознавание остановится.")
            }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(dropTargeted ? 0.06 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.7 : 0), lineWidth: 2)
                }
                .padding(6).allowsHitTesting(false).accessibilityHidden(true)
                .gentleMotion(value: dropTargeted, duration: 0.15)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in library.requestImport([url]) } }
                }
            }
            return !providers.isEmpty
        }
    }
}

private struct RecordingRow: View {
    let record: Recording

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 28, height: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: record.state == .ready ? "checkmark.circle" : "circle.dotted")
                    Text(record.state.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if let transcript = record.transcript {
                        Text(Transcript.timestamp(transcript.durationMS, subtitle: false)).monospacedDigit()
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
}

private struct RecordingDetail: View {
    @ObservedObject var library: LibraryController
    let record: Recording
    let requestDelete: () -> Void
    @ViewState(initialValue: "") private var search: String
    @ViewState(initialValue: false) private var selecting: Bool
    @ViewState(initialValue: Set<String>()) private var selectedSegments: Set<String>
    @ViewState(initialValue: true) private var mergeAssigned: Bool
    private var preview: Transcript? { library.preview(for: record.id) }
    private var hasTranscript: Bool { preview != nil || record.transcript != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(record.title).font(.system(size: 23, weight: .semibold))
                        .lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let transcript = record.transcript {
                            Label("Говорящих: \(transcript.speakers.count)", systemImage: "person.2")
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                GlassControls {
                    HStack(spacing: 10) {
                        Button(role: .destructive, action: requestDelete) {
                            Image(systemName: "trash").font(.system(size: 15))
                        }.glassControl().controlSize(.large)
                            .disabled(library.importing || library.deleting.contains(record.id))
                            .help("Удалить расшифровку").accessibilityLabel("Удалить расшифровку")
                        if record.state == .ready, record.transcript != nil {
                            Button {
                                library.requestReprocess(record)
                            } label: {
                                Image(systemName: "arrow.clockwise").font(.system(size: 15))
                            }.glassControl().fixedSize().controlSize(.large)
                                .disabled(library.active != nil || library.importing)
                                .help("Расшифровать выбранной моделью в новой записи")
                                .accessibilityLabel("Расшифровать снова")
                            Menu {
                                Button("Текст (.txt)") { library.export(record, format: "txt") }
                                Button("Субтитры (.srt)") { library.export(record, format: "srt") }
                                Button("Данные (.json)") { library.export(record, format: "json") }
                            } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
                                .glassControl().fixedSize().controlSize(.large)
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 22)

            if let context = record.meetingContext, !context.isEmpty {
                DisclosureGroup("Контекст встречи") {
                    Text(context).font(.subheadline).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }

            if record.state != .ready {
                ZStack(alignment: .leading) {
                    status.id(record.state).transition(.opacity)
                }
                .gentleMotion(value: record.state)
                .padding(.horizontal, 24).padding(.bottom, 20)
            }

            if let transcript = preview ?? record.transcript {
                PlaybackBar(player: library.player, duration: transcript.durationMS,
                            search: $search, play: { library.play(record) })
                    .padding(.horizontal, 24).padding(.vertical, 14)
                Divider()
                if record.state == .ready {
                    HStack(spacing: 12) {
                        Button(selecting ? "Готово" : "Выбрать реплики") {
                            selecting.toggle(); selectedSegments.removeAll()
                        }
                        if selecting {
                            Text("Выбрано: \(selectedSegments.count)").font(.caption)
                            Menu("Назначить говорящего") {
                                ForEach(transcript.speakers.keys.sorted { (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1) }, id: \.self) { key in
                                    Button(transcript.speakers[key] ?? key) {
                                        library.assign(record.id, segments: selectedSegments, speaker: Int(key), merge: mergeAssigned)
                                        selectedSegments.removeAll()
                                    }
                                }
                                Button("Не определён") {
                                    library.assign(record.id, segments: selectedSegments, speaker: nil, merge: false)
                                    selectedSegments.removeAll()
                                }
                            }.disabled(selectedSegments.isEmpty)
                            Toggle("Объединить соседние", isOn: $mergeAssigned).toggleStyle(.checkbox).font(.caption)
                        }
                        Spacer()
                        Button("Отменить правку", systemImage: "arrow.uturn.backward") {
                            library.undoEdit(record.id); selectedSegments.removeAll()
                        }.disabled(!library.canUndoEdit(record.id))
                    }.padding(.horizontal, 24).padding(.vertical, 8)
                }
                transcriptBody(transcript, readOnly: record.state != .ready)
                    .transition(.opacity)
            } else {
                Divider()
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 32, weight: .light))
                    Text("Здесь появится расшифровка").font(.system(size: 15, weight: .medium))
                    Text("Сначала появится текст, затем добавятся говорящие.")
                        .font(.system(size: 12)).multilineTextAlignment(.center)
                }.foregroundStyle(.secondary).padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .gentleMotion(value: hasTranscript, duration: 0.24)
            .onChange(of: record.id) { selectedSegments.removeAll(); selecting = false }
            .onChange(of: search) { selectedSegments.removeAll() }
    }

    @ViewBuilder private var status: some View {
        if library.deleting.contains(record.id) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Останавливаем обработку и удаляем запись…").font(.system(size: 12))
                Spacer()
            }
        } else if record.state == .processing {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(library.stage).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(library.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: library.progress)
                        .gentleMotion(value: library.progress, duration: 0.18)
                }
                Button("Отменить") { library.cancel(record.id) }.glassControl()
            }
        } else {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.error ?? record.state.title)
                    if record.state == .waitingForMemory {
                        // Keep height flexible: a vertical fixedSize here inflates
                        // the native split view during narrow-width fitting.
                        Text("Закройте ненужные приложения или выберите модель поменьше, затем нажмите «Повторить».")
                    }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if record.state == .queued {
                    Button("Отменить") { library.cancel(record.id) }.glassControl()
                } else {
                    Button("Повторить") { library.requestRetry(record) }.glassControl().disabled(library.active != nil)
                }
            }
        }
    }

    private func transcriptBody(_ transcript: Transcript, readOnly: Bool) -> some View {
        let matches = transcript.segments.filter { search.isEmpty || !TranscriptSearch.ranges(of: search, in: $0.text).isEmpty }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if matches.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: search.isEmpty ? "waveform" : "magnifyingglass")
                            .font(.system(size: 24, weight: .light))
                        Text(search.isEmpty ? "Речь не обнаружена" : "Совпадений нет")
                            .font(.system(size: 14, weight: .medium))
                        if !search.isEmpty { Text("Попробуйте другое слово или очистите поиск.").font(.system(size: 12)) }
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 56)
                }
                ForEach(matches) { segment in
                    SegmentView(segment: segment, transcript: transcript, readOnly: readOnly, search: search,
                        selecting: selecting && !readOnly, selected: selectedSegments.contains(segment.id),
                        toggleSelection: {
                            if !selectedSegments.insert(segment.id).inserted { selectedSegments.remove(segment.id) }
                        },
                        isFirst: segment.id == matches.first?.id, isLast: segment.id == matches.last?.id,
                        seek: { library.play(record, at: segment.startMS) },
                        rename: { speaker, name in library.rename(record.id, speaker: speaker, name: name) },
                        assign: { library.assign(record.id, segment: segment.id, speaker: $0) })
                }
            }.frame(maxWidth: 820).padding(.horizontal, 28).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct PlaybackBar: View {
    let player: AVPlayer
    let duration: Int64
    @Binding var search: String
    let play: () -> Void
    @ViewState(initialValue: false) private var playing: Bool

    var body: some View {
        GlassControls {
            HStack(spacing: 12) {
                Button {
                    if playing { player.pause() } else { play() }
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .playbackSymbolMotion()
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20, height: 30)
                        .accessibilityHidden(true)
                }.glassControl().controlSize(.large)
                    .help(playing ? "Пауза" : "Слушать")
                    .accessibilityLabel(playing ? "Пауза" : "Слушать")
                Text(Transcript.timestamp(duration, subtitle: false))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .help("Длительность записи")
                Spacer(minLength: 12)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Найти в тексте", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Очистить поиск").accessibilityLabel("Очистить поиск")
                    }
                }.font(.system(size: 12)).padding(.horizontal, 14).frame(height: 40)
                    .frame(minWidth: 160, idealWidth: 210, maxWidth: 260)
                    .glassSurface()
            }
        }.onReceive(player.publisher(for: \.rate)) { playing = $0 > 0 }
            .onDisappear { player.pause() }
    }
}

private struct SegmentView: View {
    let segment: Segment
    let transcript: Transcript
    let readOnly: Bool
    let search: String
    let selecting: Bool
    let selected: Bool
    let toggleSelection: () -> Void
    let isFirst: Bool
    let isLast: Bool
    let seek: () -> Void
    let rename: (String, String) -> Void
    let assign: (Int?) -> Void
    @ViewState(initialValue: "") private var name: String
    @ViewState(initialValue: false) private var renaming: Bool

    private var speakerColor: Color {
        guard let speaker = segment.speaker else { return .secondary }
        let colors: [Color] = [.blue, .teal, .purple, .orange, .pink, .indigo]
        return colors[speaker % colors.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if selecting {
                    Button(action: toggleSelection) {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                    }.buttonStyle(.plain)
                        .accessibilityLabel(selected ? "Снять выделение реплики" : "Выбрать реплику")
                }
                ZStack {
                    Circle().fill(speakerColor.opacity(0.12))
                    Image(systemName: segment.speaker == nil ? "questionmark" : "person.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(speakerColor)
                }.frame(width: 26, height: 26).accessibilityHidden(true)
                if readOnly {
                    Text("Предварительный текст").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                Menu {
                    if let speaker = segment.speaker {
                        Button("Переименовать…") { name = transcript.speakerName(speaker); renaming = true }
                        Divider()
                    }
                    ForEach(transcript.speakers.keys.sorted { (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1) }, id: \.self) { key in
                        Button(transcript.speakers[key] ?? key) { assign(Int(key)) }
                    }
                    Button("Не определён") { assign(nil) }
                } label: {
                    Text(segment.speaker == nil ? "Не определён" : transcript.speakerName(segment.speaker))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }.glassControl().controlSize(.small)
                    .frame(maxWidth: 190, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: true)
                    .help("Переименовать или назначить говорящего")
                }
                if segment.overlap {
                    Label("Наложение", systemImage: "waveform.path")
                        .font(.system(size: 10)).foregroundStyle(.orange).fixedSize()
                        .help("В этом фрагменте голоса накладываются друг на друга")
                        .accessibilityLabel("Наложение голосов")
                }
                Spacer(minLength: 4)
            }
            SearchHighlightedText(text: segment.text, query: search).font(.system(size: 15)).lineSpacing(5)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }.padding(.vertical, 14)
        .padding(.leading, TranscriptTimeline.gutter)
        .overlay(alignment: .leading) {
            TranscriptTimeline(timestamp: Transcript.timestamp(segment.startMS, subtitle: false),
                               color: speakerColor, isFirst: isFirst, isLast: isLast, seek: seek)
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().opacity(0.5).padding(.leading, TranscriptTimeline.gutter + 36)
            }
        }
        .alert("Имя говорящего", isPresented: $renaming) {
            TextField("Имя", text: $name)
            Button("Сохранить") { if let speaker = segment.speaker { rename(String(speaker), name) } }
            Button("Отмена", role: .cancel) {}
        }
    }
}
