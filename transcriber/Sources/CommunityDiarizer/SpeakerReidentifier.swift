@preconcurrency import CoreML
import Foundation

// The pinned Community-1 model contract: 10s audio -> FBANK -> weighted WeSpeaker.
// Tiling a short span follows FluidAudio's OfflineEmbeddingExtractor.embedSpan.
struct VoiceSpanEmbedder {
    private let fbank: MLModel
    private let embedding: MLModel
    init(directory: URL, computeUnits: MLComputeUnits) throws {
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        let units = MLModelConfiguration(); units.computeUnits = computeUnits
        fbank = try MLModel(contentsOf:directory.appendingPathComponent("FBank.mlmodelc"),configuration:cpu)
        embedding = try MLModel(contentsOf:directory.appendingPathComponent("Embedding.mlmodelc"),configuration:units)
    }
    func extract(samples: [Float], startMS: Int64, endMS: Int64) throws -> [Float] {
        guard startMS >= 0, endMS > startMS, endMS <= Int64(samples.count)*1000/16000 else {
            throw PipelineError("Неверные границы голосового образца")
        }
        let start = Int(startMS)*16, count = min(Int(endMS-startMS)*16,160000)
        let audio = try MLMultiArray(shape:[1,1,160000],dataType:.float32)
        let pointer = audio.dataPointer.assumingMemoryBound(to:Float.self)
        for index in 0..<160000 { pointer[index] = samples[start+index%count] }
        let output = try fbank.prediction(from:MLDictionaryFeatureProvider(dictionary:["audio":MLFeatureValue(multiArray:audio)]))
        guard let features = output.featureValue(for:"fbank_features")?.multiArrayValue,
              features.dataType == .float32, features.shape.map(\.intValue) == [1,1,80,998] else {
            throw PipelineError("Неверный формат голосовых признаков")
        }
        let silence = SpanFeatureNormalization.silentFrames(audio:UnsafeBufferPointer(start:pointer,count:160000),frameCount:998)
        // Core ML pads rows (1008, not 998, on the tested Mac); honor its strides.
        SpanFeatureNormalization.recenter(features:features.dataPointer.assumingMemoryBound(to:Float.self),bandCount:80,
            bandStride:features.strides[2].intValue,frameStride:features.strides[3].intValue,silent:silence)
        let weights = try MLMultiArray(shape:[1,589],dataType:.float32)
        let mask = weights.dataPointer.assumingMemoryBound(to:Float.self)
        for index in 0..<589 { mask[index] = 1 }
        let prediction = try embedding.prediction(from:MLDictionaryFeatureProvider(dictionary:[
            "fbank_features":MLFeatureValue(multiArray:features),"weights":MLFeatureValue(multiArray:weights)]))
        guard let result = prediction.featureValue(for:"embedding")?.multiArrayValue,
              result.dataType == .float32, result.count == 256 else { throw PipelineError("Неверный голосовой вектор") }
        let vector = Array(UnsafeBufferPointer(start:result.dataPointer.assumingMemoryBound(to:Float.self),count:256))
        guard vector.allSatisfy(\.isFinite) else { throw PipelineError("Нечисловой голосовой вектор") }
        return vector
    }
}

enum SpeakerReidentifier {
    static func refine(_ turns: [SpeakerTurn], samples: [Float], modelDirectory: URL,
                       computeUnits: MLComputeUnits) throws -> [SpeakerTurn] {
        guard Set(turns.map(\.speaker)).count >= 2 else { return turns }
        let exclusive = ReidentificationPolicy.exclusiveFlags(turns)
        let references = ReidentificationPolicy.references(turns,exclusive:exclusive)
        let groups = Dictionary(grouping:references,by: \.speaker)
        guard groups.values.filter({$0.count>=3}).count >= 2 else {
            diagnostic("speaker-reid: insufficient reference speech; keeping assignments")
            return turns
        }
        let extractor = try VoiceSpanEmbedder(directory:modelDirectory,computeUnits:computeUnits)
        let observations = try references.map {
            VoiceObservation(speaker:$0.speaker,vector:try extractor.extract(samples:samples,startMS:$0.startMS,endMS:$0.endMS))
        }
        let profiles = ReidentificationPolicy.profiles(from:observations)
        let referenceIndices = Set(references.map(\.turnIndex))
        var refined = turns, checked = 0, changed = 0
        for index in turns.indices {
            let turn = turns[index], duration = turn.endMS-turn.startMS
            guard exclusive[index], !referenceIndices.contains(index), duration >= 800, duration <= 4000,
                  profiles.first(where:{$0.speaker==turn.speaker})?.trusted == true else { continue }
            let vector = try extractor.extract(samples:samples,startMS:turn.startMS,endMS:turn.endMS)
            checked += 1
            if let speaker = ReidentificationPolicy.replacement(for:vector,current:turn.speaker,profiles:profiles) {
                refined[index] = SpeakerTurn(startMS:turn.startMS,endMS:turn.endMS,speaker:speaker)
                changed += 1
                diagnostic("speaker-reid: \(turn.startMS)-\(turn.endMS) \(turn.speaker)->\(speaker)")
            }
        }
        diagnostic("speaker-reid: checked=\(checked) changed=\(changed) trustedProfiles=\(profiles.filter(\.trusted).count)")
        return refined
    }
}
