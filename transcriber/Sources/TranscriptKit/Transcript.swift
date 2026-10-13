import Foundation

public enum TranscriptError: LocalizedError {
    case invalidDocument, unsafePath
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "Расшифровка повреждена или создана другой версией приложения."
        case .unsafePath: return "Недопустимый путь записи."
        }
    }
}

public struct Segment: Codable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public var startMS: Int64
    public var endMS: Int64
    public var speaker: Int?
    public var text: String
    public var overlap: Bool
    public init(startMS: Int64, endMS: Int64, speaker: Int?, text: String, overlap: Bool) {
        self.startMS = startMS; self.endMS = endMS; self.speaker = speaker
        self.text = text; self.overlap = overlap
    }
}

public struct DiarizationProvenance: Codable, Equatable {
    public var engine: String
    public var sdkRevision: String
    public var modelRevision: String
    public var modelManifestSHA256: String
    public var configurationSHA256: String
    public var computeUnits: String
}

public struct Transcript: Codable, Equatable {
    public var schemaVersion = 1
    public var durationMS: Int64
    public var segments: [Segment]
    public var speakers: [String: String]
    public var model: String
    public var diarization: DiarizationProvenance? = nil
    public init(durationMS: Int64, segments: [Segment], speakers: [String: String], model: String) {
        self.durationMS = durationMS; self.segments = segments; self.speakers = speakers; self.model = model
    }
    public func validate() throws {
        guard schemaVersion == 1, durationMS >= 0, durationMS <= 14_400_000,
              Set(segments.map(\.id)).count == segments.count else { throw TranscriptError.invalidDocument }
        var lastStart: Int64 = -1
        for row in segments {
            guard row.startMS >= 0, row.startMS >= lastStart, row.endMS > row.startMS,
                  row.endMS <= durationMS, row.speaker.map({ $0 >= 0 && speakers[String($0)] != nil }) ?? true
            else { throw TranscriptError.invalidDocument }
            lastStart = row.startMS
        }
    }
    public func speakerName(_ id: Int?) -> String {
        id.flatMap { speakers[String($0)] } ?? "Говорящий не определён"
    }
    public var plainText: String {
        segments.map { "[\(Self.timestamp($0.startMS, subtitle: false))] \(speakerName($0.speaker)): \($0.text)" }
            .joined(separator: "\n\n")
    }
    public var srt: String {
        segments.enumerated().map { index, row in
            let content = "\(speakerName(row.speaker)): \(row.text)"
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
            return "\(index + 1)\n\(Self.timestamp(row.startMS)) --> \(Self.timestamp(row.endMS))\n\(content)\n\n"
        }.joined()
    }
    public static func timestamp(_ ms: Int64, subtitle: Bool = true) -> String {
        let seconds = max(0, ms) / 1000
        let clock = String(format: "%02lld:%02lld:%02lld", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        return subtitle ? clock + String(format: ",%03lld", max(0, ms) % 1000) : clock
    }
}

public enum RecordingState: String, Codable {
    case queued, processing, ready, failed, cancelled, interrupted, waitingForMemory
    public var title: String {
        switch self {
        case .queued: return "В очереди"
        case .processing: return "Обрабатывается"
        case .ready: return "Готово"
        case .failed: return "Не удалось обработать"
        case .cancelled: return "Отменено"
        case .interrupted: return "Обработка прервана"
        case .waitingForMemory: return "Недостаточно памяти"
        }
    }
}

public struct Recording: Codable, Identifiable {
    public var id = UUID()
    public var title: String
    public var sourceName: String
    public var meetingContext: String?
    public var createdAt = Date()
    public var state: RecordingState = .queued
    public var transcript: Transcript?
    public var error: String?
    public init(title: String, sourceName: String) { self.title = title; self.sourceName = sourceName }
}

public struct AttemptGate {
    private var current: UUID?
    public init() {}
    public mutating func begin() -> UUID { let id = UUID(); current = id; return id }
    public mutating func cancel() { current = nil }
    public func accepts(_ id: UUID) -> Bool { current == id }
}
