@preconcurrency import CoreML
import FluidAudio
import Foundation

enum CommunityEngine {
    // Pin the high-overlap window cadence; SDK's 0.2 default explicitly trades DER for speed.
    private static let minimumSegmentDuration = 0.5
    private static let zeroVoteEnabled = true
    static let settings = "offline-v1;step=0.1;exclusive=false;minimum=\(minimumSegmentDuration);zeroVote=\(zeroVoteEnabled);zeroVoteMinimum=0.4;embeddingSkip=none;otherDefaults=04e363c29d9a754022d602d6fe1468ab80a0f705;\(ReidentificationPolicy.settings)"
    static func run(samples: [Float], modelDirectory: URL, computeUnits: MLComputeUnits) async throws -> DiarizationResult {
        ModelHub.offlineMode = true
        // Explicit local loads avoid ModelHub's cache folder convention and any repair downloads.
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let config = MLModelConfiguration(); config.computeUnits = units
            return try MLModel(contentsOf:modelDirectory.appendingPathComponent(name + ".mlmodelc"),configuration:config)
        }
        let json = try JSONSerialization.jsonObject(with:regularData(modelDirectory.appendingPathComponent("plda-parameters.json"),limit:1048576)) as? [String:Any]
        guard let tensors = json?["tensors"] as? [String:Any], let psi = tensors["psi"] as? [String:Any],
              let base64 = psi["data_base64"] as? String, let bytes = Data(base64Encoded:base64),
              !bytes.isEmpty, bytes.count % 4 == 0 else { throw PipelineError("Неверные параметры PLDA") }
        var values = [Float](repeating:0,count:bytes.count/4)
        _ = values.withUnsafeMutableBytes { bytes.copyBytes(to:$0) }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw PipelineError("Неверные параметры PLDA") }
        let models = try OfflineDiarizerModels(segmentationModel:model("Segmentation",computeUnits),
            fbankModel:model("FBank",.cpuOnly),embeddingModel:model("Embedding",computeUnits),
            pldaRhoModel:model("PldaRho",computeUnits),pldaPsi:values.map(Double.init),compilationDuration:0)
        var config = OfflineDiarizerConfig(); config.segmentation.stepRatio = 0.1
        config.postProcessing.exclusiveSegments = false
        config.embedding.minSegmentDurationSeconds = minimumSegmentDuration
        config.zeroVoteReembed.enabled = zeroVoteEnabled
        config.zeroVoteReembed.minDurationSeconds = 0.4
        diagnostic("community-1 config: step=\(config.segmentation.stepRatio) exclusive=\(config.postProcessing.exclusiveSegments) minimum=\(config.embedding.minSegmentDurationSeconds) zeroVote=\(config.zeroVoteReembed.enabled)")
        let manager = OfflineDiarizerManager(config:config)
        manager.initialize(models:models)
        return try await manager.process(audio:samples) { done,total in
            emitProgress(total > 0 ? Double(done)/Double(total) * 0.9 : 0)
        }
    }
}
