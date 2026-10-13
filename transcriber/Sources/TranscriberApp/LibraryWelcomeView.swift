import SwiftUI

struct LibraryWelcomeView: View {
    let hasRecordings: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Новая расшифровка")
                    .font(.system(size: 23, weight: .semibold))
                Text(hasRecordings ? "Выберите запись слева или загрузите новую." : "Из записи — в понятный текст по говорящим.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 22)

            HStack(spacing: 12) {
                Image(systemName: "arrow.down.document")
                    .font(.system(size: 20, weight: .light)).foregroundStyle(.tint)
                    .frame(width: 28).accessibilityHidden(true)
                Text("Перетащите сюда аудио или видео")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }.padding(.horizontal, 24).padding(.bottom, 22)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Пример результата")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("2 говорящих")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.vertical, 20)

                    WelcomeSpeakerRow(name: "Говорящий 1", time: "00:00:00", color: .blue,
                        isFirst: true, isLast: false,
                        text: "Обсудим запуск проекта и задачи на эту неделю.")
                    WelcomeSpeakerRow(name: "Говорящий 2", time: "00:00:08", color: .teal,
                        isFirst: false, isLast: true,
                        text: "Я проверю API и подготовлю результаты к следующей встрече.")

                    Text("В готовой расшифровке можно назвать говорящих, скопировать текст и послушать нужный фрагмент.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 36).padding(.vertical, 22)
                }.frame(maxWidth: 820).padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

// An illustration of the output, not a stored Recording or an interactive editor.
private struct WelcomeSpeakerRow: View {
    let name: String
    let time: String
    let color: Color
    let isFirst: Bool
    let isLast: Bool
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(color.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text(name).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
            }
            Text(text).font(.system(size: 15)).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }.padding(.vertical, 14)
            .padding(.leading, TranscriptTimeline.gutter)
            .overlay(alignment: .leading) {
                TranscriptTimeline(timestamp: time, color: color, isFirst: isFirst, isLast: isLast)
            }
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider().opacity(0.5).padding(.leading, TranscriptTimeline.gutter + 36)
                }
            }
    }
}
