import Foundation

public enum MeetingContext {
    public static let characterLimit = 300

    public static func validationMessage(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > characterLimit || trimmed.utf8.count > 4096 {
            return "Сократите список до \(characterLimit) символов: оставьте только нужные имена, названия и термины."
        }
        if trimmed.contains("\0") { return "Удалите из контекста непечатаемые символы." }
        return nil
    }

    public static func validated(_ text: String?) throws -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = validationMessage(for: trimmed) {
            throw NSError(domain: "MeetingContext", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
