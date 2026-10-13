import Foundation
import Darwin
import FluidAudio

func emitProgress(_ fraction: Double) {
    let text = "{\"stage\":\"speakers\",\"progress\":\(min(1,max(0,fraction)))}\n"
    FileHandle.standardOutput.write(Data(text.utf8))
}
func diagnostic(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

@main struct DiarizerMain {
    static func main() async {
        umask(0o077)
        var options: [String:String] = [:]
        let args = Array(CommandLine.arguments.dropFirst())
        let allowed = Set(["--attempt-dir","--model-dir","--model-manifest","--cache-dir","--compute-units"])
        guard args.count % 2 == 0 else { exit(2) }
        for i in stride(from:0,to:args.count,by:2) {
            guard allowed.contains(args[i]), options[args[i]] == nil else { exit(2) }
            options[args[i]] = args[i+1]
        }
        guard let attempt = options["--attempt-dir"], let model = options["--model-dir"],
              let manifest = options["--model-manifest"], let cacheRoot = options["--cache-dir"] else { exit(2) }
        let units = options["--compute-units"] ?? "all"
        guard units == "all" || units == "cpu" else { exit(2) }
        do {
            let directory = URL(fileURLWithPath:attempt)
            let (input,samples) = try PreparedInput.load(at:directory)
            let lock: ModelLock
            do { lock = try ModelLock.load(URL(fileURLWithPath:manifest),directory:URL(fileURLWithPath:model)) }
            catch { diagnostic("Community-1: \(error)"); exit(4) }
            let provenance = Provenance(engine:lock.engine,sdkRevision:lock.sdkRevision,modelRevision:lock.modelRevision,
                modelManifestSHA256:lock.modelManifestSHA256,configurationSHA256:digest(Data(CommunityEngine.settings.utf8)),computeUnits:units)
            let cache = SpeakerCache(directory:URL(fileURLWithPath:cacheRoot).appendingPathComponent("community-1-v1"))
            let key = try SpeakerCache.key(input:input,provenance:provenance)
            if let cached = cache.load(key:key,durationMS:input.durationMS,provenance:provenance) {
                try atomicJSON(cached,to:directory.appendingPathComponent("turns.json")); diagnostic("speaker-cache: hit community-1"); emitProgress(1); return
            }
            emitProgress(0)
            var turns: [SpeakerTurn] = []
            var cacheable = true
            if samples.contains(where:{ abs($0) > 0.000001 }) {
                do {
                let result = try await CommunityEngine.run(samples:samples,modelDirectory:URL(fileURLWithPath:model),computeUnits:units == "all" ? .all : .cpuOnly)
                turns = try TurnOutput.normalized(result.segments.map { (Double($0.startTimeSeconds),Double($0.endTimeSeconds),$0.speakerId) },durationMS:input.durationMS)
                do {
                    turns = try SpeakerReidentifier.refine(turns,samples:samples,modelDirectory:URL(fileURLWithPath:model),computeUnits:units == "all" ? .all : .cpuOnly)
                } catch {
                    // Retry refinement on the next run after a transient failure.
                    cacheable = false
                    // This conservative refinement is optional; base diarization remains valid.
                    diagnostic("speaker-reid: unavailable (\(error)); keeping base assignments")
                }
                } catch OfflineDiarizationError.noSpeechDetected { turns = [] }
            }
            let output = TurnOutput(durationMS:input.durationMS,provenance:provenance,turns:turns)
            try output.validate(); try atomicJSON(output,to:directory.appendingPathComponent("turns.json"))
            if cacheable {
                do { try cache.save(output,key:key) } catch { diagnostic("speaker-cache: write failed") }
            }
            diagnostic("community-1: turns=\(turns.count) speakers=\(Set(turns.map(\.speaker)).count)"); emitProgress(1)
        } catch OfflineDiarizationError.noSpeechDetected {
            diagnostic("Community-1: no speech detected"); exit(1)
        } catch { diagnostic("Community-1: \(error)"); exit(1) }
    }
}
