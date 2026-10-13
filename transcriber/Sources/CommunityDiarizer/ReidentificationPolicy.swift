import Foundation

struct VoiceObservation { let speaker: Int; let vector: [Float] }
struct VoiceProfile { let speaker: Int; let vector: [Float]; let trusted: Bool }
struct VoiceReference { let turnIndex: Int; let speaker: Int; let startMS: Int64; let endMS: Int64 }

enum ReidentificationPolicy {
    static let settings = "short-reid-v1;span=.8-4;reference>=4,max6,spacing15,trim.2,window8;coherence=.6,min3,top4;cosine=.6;margin=.2;exclusiveOnly=true"

    static func unit(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }
    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return -.infinity }
        return zip(a,b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    }

    // Sorted input is guaranteed by TurnOutput.normalized/cache validation.
    static func exclusiveFlags(_ turns: [SpeakerTurn]) -> [Bool] {
        var prefixEnd: [Int64] = [], maximum: Int64 = 0
        for turn in turns { maximum = max(maximum,turn.endMS); prefixEnd.append(maximum) }
        return turns.map { turn in
            var low = 0, high = turns.count
            while low < high {
                let middle = (low+high)/2
                if prefixEnd[middle] <= turn.startMS { low = middle+1 } else { high = middle }
            }
            var index = low
            while index < turns.count, turns[index].startMS < turn.endMS {
                if turns[index].speaker != turn.speaker && turns[index].endMS > turn.startMS { return false }
                index += 1
            }
            return true
        }
    }

    static func references(_ turns: [SpeakerTurn], exclusive: [Bool]) -> [VoiceReference] {
        guard turns.count == exclusive.count else { return [] }
        let candidates = turns.indices.filter { exclusive[$0] && turns[$0].endMS-turns[$0].startMS >= 4000 }
            .sorted {
                let a = turns[$0].endMS-turns[$0].startMS, b = turns[$1].endMS-turns[$1].startMS
                return a == b ? $0 < $1 : a > b
            }
        var centers: [Int:[Int64]] = [:], output: [VoiceReference] = []
        for index in candidates {
            let turn = turns[index], center = turn.startMS+(turn.endMS-turn.startMS)/2
            let selected = centers[turn.speaker] ?? []
            guard selected.count < 6, selected.allSatisfy({ abs(center-$0) >= 15000 }) else { continue }
            let half = min(Int64(4000),(turn.endMS-turn.startMS)/2-200)
            output.append(VoiceReference(turnIndex:index,speaker:turn.speaker,startMS:center-half,endMS:center+half))
            centers[turn.speaker,default:[]].append(center)
        }
        return output
    }

    static func profiles(from observations: [VoiceObservation]) -> [VoiceProfile] {
        var bySpeaker: [Int:[[Float]]] = [:]
        for item in observations {
            guard let vector = unit(item.vector) else { continue }
            if let first = bySpeaker[item.speaker]?.first, first.count != vector.count { continue }
            bySpeaker[item.speaker,default:[]].append(vector)
        }
        return bySpeaker.keys.sorted().compactMap { speaker in
            let vectors = bySpeaker[speaker]!
            let medoid = vectors.indices.max { left,right in
                vectors.reduce(0.0) { $0+dot(vectors[left],$1) } < vectors.reduce(0.0) { $0+dot(vectors[right],$1) }
            }!
            let ranked = vectors.indices.sorted {
                let a = dot(vectors[$0],vectors[medoid]), b = dot(vectors[$1],vectors[medoid])
                return a == b ? $0 < $1 : a > b
            }
            let consistent = ranked.filter { dot(vectors[$0],vectors[medoid]) >= 0.6 }.prefix(4)
            guard consistent.count >= 3 else { return VoiceProfile(speaker:speaker,vector:vectors[medoid],trusted:false) }
            var mean = [Float](repeating:0,count:vectors[0].count)
            for index in consistent { for k in mean.indices { mean[k] += vectors[index][k] } }
            guard let centroid = unit(mean) else { return nil }
            return VoiceProfile(speaker:speaker,vector:centroid,trusted:true)
        }
    }

    static func replacement(for vector: [Float], current: Int, profiles: [VoiceProfile]) -> Int? {
        guard profiles.count >= 2, profiles.first(where:{$0.speaker==current})?.trusted == true,
              let normalized = unit(vector) else { return nil }
        let ranked = profiles.map { ($0,dot(normalized,$0.vector)) }.sorted { $0.1 > $1.1 }
        let best = ranked[0]
        guard best.0.trusted, best.0.speaker != current, best.1 >= 0.6,
              best.1-ranked[1].1 >= 0.2 else { return nil }
        return best.0.speaker
    }
}
