import Foundation

public enum TranscriptSearch {
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let match = text.range(of: query, options: .caseInsensitive,
                                     range: start..<text.endIndex, locale: .current),
              match.lowerBound < match.upperBound {
            result.append(match)
            start = match.upperBound
        }
        return result
    }
}
