import Foundation

extension Transcript {
    public mutating func assignSpeaker(_ speaker: Int?, to ids: Set<String>, merge: Bool) {
        guard !ids.isEmpty, speaker.map({ speakers[String($0)] != nil }) ?? true else { return }
        for index in segments.indices where ids.contains(segments[index].id) {
            segments[index].speaker = speaker
        }
        guard merge, speaker != nil else { return }
        var rows: [Segment] = []
        var touched: [Bool] = []
        for row in segments {
            let selected = ids.contains(row.id)
            if let last = rows.last, last.speaker == speaker, row.speaker == speaker,
               !last.overlap, !row.overlap, row.startMS >= last.endMS,
               row.startMS - last.endMS <= 1000, row.endMS - last.startMS <= 20000,
               selected || touched.last == true {
                rows[rows.count - 1].text += " " + row.text
                rows[rows.count - 1].endMS = row.endMS
                touched[touched.count - 1] = true
            } else { rows.append(row); touched.append(selected) }
        }
        segments = rows
    }
}
