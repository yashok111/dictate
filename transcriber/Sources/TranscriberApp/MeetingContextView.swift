import SwiftUI
import TranscriptKit

private typealias ContextViewState<Value> = SwiftUI.State<Value>

struct MeetingContextView: View {
    let request: MeetingContextRequest
    let confirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ContextViewState private var text: String

    init(request: MeetingContextRequest, confirm: @escaping (String) -> Void) {
        self.request = request
        self.confirm = confirm
        _text = ContextViewState(initialValue: request.context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Контекст встречи").font(.title2.bold())
            Text(request.title ?? (request.urls.count == 1 ? request.urls[0].lastPathComponent : "Записей: \(request.urls.count)"))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Text("Необязательно. Перечислите через запятую имена, названия компаний и важные термины, которые могут прозвучать в записи.")
                .fixedSize(horizontal: false, vertical: true)
            GlassControls {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .font(.body).padding(12).frame(height: 130)
                    .glassSurface(radius: 18)
                    .accessibilityLabel("Контекст встречи")
            }
            HStack {
                Text("Сохраняется только с этой записью, на вашем Mac.")
                Spacer()
                Text("\(text.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(MeetingContext.characterLimit)").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            if let message = MeetingContext.validationMessage(for: text) {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Например: Анна Смирнова, Алексей, TestFlight, onboarding, API.\nПишите коротким списком. Заполнять все \(MeetingContext.characterLimit) символов не нужно.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if request.urls.count > 1 {
                Text("Этот контекст будет применён ко всем выбранным записям.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GlassControls {
                HStack {
                    Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                        .glassControl().controlSize(.large)
                    Spacer()
                    Button("Начать расшифровку") { confirm(text) }
                        .glassControl(prominent: true).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(MeetingContext.validationMessage(for: text) != nil)
                }
            }
        }.padding(24).frame(width: 560)
    }
}
