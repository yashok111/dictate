import SwiftUI

// The rail follows row height, not audio duration. Overlaying it on the row keeps
// multiline text as the only source of vertical sizing.
struct TranscriptTimeline: View {
    static let gutter: CGFloat = 88
    private let markerX: CGFloat = 74
    private let markerY: CGFloat = 27

    let timestamp: String
    let color: Color
    let isFirst: Bool
    let isLast: Bool
    var seek: (() -> Void)? = nil
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: markerX, y: isFirst ? markerY : 0))
                    path.addLine(to: CGPoint(x: markerX, y: isLast ? markerY : geometry.size.height))
                }.stroke(color.opacity(contrast == .increased ? 1 : 0.65), lineWidth: 3)

                Circle().fill(color)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: 1.5))
                    .position(x: markerX, y: markerY)
            }.allowsHitTesting(false).accessibilityHidden(true)

            Group {
                if let seek {
                    Button(action: seek) { timeLabel }
                        .buttonStyle(.plain)
                        .help("Слушать с \(timestamp)")
                        .accessibilityLabel("Слушать с \(timestamp)")
                } else {
                    timeLabel
                }
            }.padding(.top, 14)
        }.frame(width: Self.gutter)
    }

    private var timeLabel: some View {
        Text(timestamp).font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 62, height: 26, alignment: .leading)
            .contentShape(Rectangle())
    }
}
