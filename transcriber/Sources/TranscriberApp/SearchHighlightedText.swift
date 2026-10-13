import SwiftUI
import TranscriptKit

struct SearchHighlightedText: View {
    let text: String
    let query: String
    private static let highlight = Color(red: 1, green: 0.88, blue: 0.25)

    var body: some View {
        let matches = TranscriptSearch.ranges(of: query, in: text)
        if matches.isEmpty {
            Text(text)
        } else if #available(macOS 15.0, *) {
            // Selectable macOS Text uses an AppKit renderer and bypasses TextRenderer.
            // Draw only the backgrounds in a nonselectable layer with identical layout;
            // the foreground remains one native selectable/accessibility text element.
            Text(attributedText(matches, includeBackground: false))
                .background {
                    markedText(matches).textRenderer(SearchHighlightRenderer(color: Self.highlight))
                        .textSelection(.disabled)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
        } else {
            Text(attributedText(matches, includeBackground: true))
        }
    }

    @available(macOS 15.0, *)
    private func markedText(_ matches: [Range<String.Index>]) -> Text {
        var result = Text("")
        var start = text.startIndex
        for match in matches {
            let prefix = Text(String(text[start..<match.lowerBound]))
            let highlighted = Text(String(text[match])).foregroundColor(.black).customAttribute(SearchMatchAttribute())
            result = Text("\(result)\(prefix)\(highlighted)")
            start = match.upperBound
        }
        return Text("\(result)\(Text(String(text[start...])))")
    }

    private func attributedText(_ matches: [Range<String.Index>], includeBackground: Bool) -> AttributedString {
        var result = AttributedString(text)
        for match in matches {
            if let range = Range(match, in: result) {
                if includeBackground { result[range].backgroundColor = Self.highlight }
                result[range].foregroundColor = .black
            }
        }
        return result
    }
}

@available(macOS 15.0, *)
private struct SearchMatchAttribute: TextAttribute {}

@available(macOS 15.0, *)
private struct SearchHighlightRenderer: TextRenderer {
    let color: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[SearchMatchAttribute.self] != nil {
                    let rect = run.typographicBounds.rect.insetBy(dx: -1.5, dy: -1)
                    context.fill(RoundedRectangle(cornerRadius: 3).path(in: rect), with: .color(color))
                }
            }
        }
    }
}
