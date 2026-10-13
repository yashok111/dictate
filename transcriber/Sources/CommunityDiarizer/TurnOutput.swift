import Foundation
struct SpeakerTurn: Codable, Equatable { let startMS: Int64; let endMS: Int64; let speaker: Int }
struct Provenance: Codable, Equatable {
    let engine: String
    let sdkRevision: String
    let modelRevision: String
    let modelManifestSHA256: String
    let configurationSHA256: String
    let computeUnits: String
}
struct TurnOutput: Codable, Equatable {
    var schemaVersion = 1
    let durationMS: Int64
    let provenance: Provenance
    let turns: [SpeakerTurn]
    func validate() throws {
        guard schemaVersion == 1, (0...14400000).contains(durationMS), turns.count <= 100000,
              provenance.engine == "community-1-fluidaudio" else { throw PipelineError("Неверные реплики") }
        var previous: Int64 = -1
        for turn in turns {
            guard turn.startMS >= 0, turn.startMS >= previous, turn.endMS > turn.startMS,
                  turn.endMS <= durationMS, (0...Int(Int32.max)).contains(turn.speaker) else { throw PipelineError("Неверные интервалы реплик") }
            previous = turn.startMS
        }
    }
    static func normalized(_ segments: [(Double,Double,String)], durationMS: Int64) throws -> [SpeakerTurn] {
        for (start,end,_) in segments {
            guard start.isFinite, end.isFinite, start >= 0, end > start, end <= 14410 else { throw PipelineError("Неверные интервалы Community-1") }
        }
        let sorted = segments.sorted { $0.0 == $1.0 ? ($0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1) : $0.0 < $1.0 }
        var labels: [String:Int] = [:], output: [SpeakerTurn] = []
        for (start,end,label) in sorted {
            let a = Int64((start * 1000).rounded()), b = min(durationMS,Int64((end * 1000).rounded()))
            guard a < b else { continue }
            if labels[label] == nil { labels[label] = labels.count }
            output.append(SpeakerTurn(startMS:a,endMS:b,speaker:labels[label]!))
        }
        return output
    }
}
