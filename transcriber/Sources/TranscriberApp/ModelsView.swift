import SwiftUI
import TranscriptKit

private typealias ModelViewState<Value> = SwiftUI.State<Value>

struct ModelsView: View {
    @ObservedObject var controller: ModelsController
    var firstRun = false
    @Environment(\.dismiss) private var dismiss
    @ModelViewState(initialValue: nil) private var deletion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GlassControls {
                HStack {
                    Text(firstRun ? "Подготовим Transcriber" : "Модели распознавания").font(.title2.bold())
                    Spacer()
                    Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                        .glassControl().controlSize(.large)
                }
            }
            Text("Для загрузки моделей подключитесь к корпоративной сети или VPN VK. После загрузки речь и голоса обрабатываются на вашем Mac, без интернета.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("В каждый набор входят Community-1 для говорящих и общая модель уточнения времени слов (317 МБ). Уже загруженные файлы используются повторно.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !controller.prepared { ProgressView("Проверяем установленные модели…") }
            ScrollView {
                GlassControls {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(controller.catalog.profiles) { profile in
                            modelRow(profile)
                        }
                        if let message = controller.error ?? controller.snapshot.error {
                            Text(message).foregroundStyle(.red).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
        }
        .padding(24).frame(width: 580, height: 540)
        .task { await controller.prepare() }
        .alert("Удалить модель?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Удалить", role: .destructive) { if let deletion { controller.remove(profileID: deletion) }; deletion = nil }
            Button("Отмена", role: .cancel) { deletion = nil }
        } message: { Text("Расшифровки сохранятся. Для нового распознавания эту модель можно будет скачать снова.") }
    }

    private func modelRow(_ profile: CatalogProfile) -> some View {
        let ready = controller.readyProfileIDs.contains(profile.id)
        let selected = controller.snapshot.profileID == profile.id
        let phase = selected ? controller.snapshot.phase : .absent
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.title).font(.headline)
                    Text(ready ? "Установлена · доступна офлайн" : "Скачать: \(ByteCountFormatter.string(fromByteCount: controller.downloadBytes(for: profile.id), countStyle: .file))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("На диске: \(ByteCountFormatter.string(fromByteCount: controller.installedBytes(for: profile.id), countStyle: .file)) · включая общие модели")
                        .font(.caption).foregroundStyle(.secondary)
                    if !profile.automatic {
                        Text("Дополнительная модель · требует больше памяти")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if ready {
                    Button("Удалить", role: .destructive) { deletion = profile.id }
                        .glassControl().controlSize(.large)
                        .disabled(controller.isBusy || controller.inUse.contains(profile.id))
                } else if selected && controller.isBusy {
                    Button("Пауза") { controller.pause() }
                        .glassControl().controlSize(.large)
                } else {
                    Button(phase == .paused ? "Продолжить" : phase == .failed ? "Повторить" : firstRun && profile.automatic ? "Скачать и начать" : "Скачать") {
                        controller.install(profileID: profile.id)
                    }
                    .glassControl(prominent: profile.automatic).controlSize(.large)
                    .disabled(!controller.prepared || controller.isBusy)
                }
            }
            if selected && controller.isBusy {
                if phase == .downloading {
                    if let total = controller.snapshot.total, total > 0 {
                        ProgressView(value: Double(controller.snapshot.received), total: Double(total))
                        Text("\(ByteCountFormatter.string(fromByteCount: controller.snapshot.received, countStyle: .file)) из \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · текущий файл")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView("Скачиваем…") }
                } else { ProgressView("Проверяем…") }
            }
            if selected && (phase == .paused || phase == .failed) {
                Button("Удалить загрузку") { controller.discard(profileID: profile.id) }
                    .font(.caption).glassControl().controlSize(.small)
            }
        }
        .padding(16).glassSurface(radius: 18)
    }
}
