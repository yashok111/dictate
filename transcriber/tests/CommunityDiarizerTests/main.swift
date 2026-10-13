import Foundation
func check(_ condition: @autoclosure () throws -> Bool, _ message:String) throws {
    if try !condition() { throw PipelineError(message) }
}
func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw PipelineError("Accepted invalid input")
}
do {
    let turns = try TurnOutput.normalized([(0,0.5,"a"),(0.3,0.8,"b"),(0.8,1.2,"a")],durationMS:1000)
    try check(turns.map(\.speaker) == [0,1,0],"Returning voice changed identity")
    try check(turns.map(\.endMS) == [500,800,1000],"Overlap/tail clipping changed")
    try rejects { _ = try TurnOutput.normalized([(Double.nan,1,"a")],durationMS:1000) }
    try check(try TurnOutput.normalized([],durationMS:0).isEmpty,"Empty speech created speakers")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let input = PreparedInput(schemaVersion:1,sampleRate:16000,sampleCount:16000,durationMS:1000,pcmFormat:"f32le-mono",
        decodeVersion:1,sourceSHA256:String(repeating:"a",count:64),pcmFile:"audio.f32",wordsFile:"words.json",asrModel:"one")
    let provenance = Provenance(engine:"community-1-fluidaudio",sdkRevision:"sdk",modelRevision:"model",modelManifestSHA256:"files",configurationSHA256:"config",computeUnits:"all")
    let output = TurnOutput(durationMS:1000,provenance:provenance,turns:turns)
    let cache = SpeakerCache(directory:root)
    let key = try SpeakerCache.key(input:input,provenance:provenance)
    try cache.save(output,key:key)
    try check(cache.load(key:key,durationMS:1000,provenance:provenance) == output,"Cache roundtrip failed")
    try check(cache.load(key:key,durationMS:999,provenance:provenance) == nil,"Cache accepted different duration")
    let other = Provenance(engine:provenance.engine,sdkRevision:"changed",modelRevision:"model",modelManifestSHA256:"files",configurationSHA256:"config",computeUnits:"all")
    try check(try SpeakerCache.key(input:input,provenance:other) != key,"SDK update reused cache")
    try Data("broken".utf8).write(to:root.appendingPathComponent(key + ".json"))
    try check(cache.load(key:key,durationMS:1000,provenance:provenance) == nil,"Corrupt cache accepted")
    let profiles = [VoiceProfile(speaker:0,vector:[1,0],trusted:true), VoiceProfile(speaker:1,vector:[0,1],trusted:true)]
    try check(ReidentificationPolicy.replacement(for:[0.1,1],current:0,profiles:profiles) == 1,"Clear alternative voice was not selected")
    try check(ReidentificationPolicy.replacement(for:[0.7,0.71],current:0,profiles:profiles) == nil,"Ambiguous voice was changed")
    try check(ReidentificationPolicy.replacement(for:[1,0.1],current:0,profiles:profiles) == nil,"Matching speaker changed")
    try check(ReidentificationPolicy.replacement(for:[Float.nan,0],current:0,profiles:profiles) == nil,"Nonfinite embedding accepted")
    let weak = [profiles[0], VoiceProfile(speaker:1,vector:[0,1],trusted:false)]
    try check(ReidentificationPolicy.replacement(for:[0,1],current:0,profiles:weak) == nil,"Rare speaker promoted without enough reference data")
    try check(ReidentificationPolicy.replacement(for:[1,0],current:1,profiles:weak) == nil,"Rare speaker removed without enough reference data")
    let trained = ReidentificationPolicy.profiles(from:[
        VoiceObservation(speaker:0,vector:[1,0]),VoiceObservation(speaker:0,vector:[1,0.1]),
        VoiceObservation(speaker:0,vector:[1,0.2]),VoiceObservation(speaker:0,vector:[-1,0]),
        VoiceObservation(speaker:1,vector:[0,1])])
    try check(trained.first(where:{$0.speaker==0})?.trusted == true,"Consistent references rejected")
    try check(trained.first(where:{$0.speaker==1})?.trusted == false,"Single reference trusted")
    let referenceTurns = [SpeakerTurn(startMS:0,endMS:10000,speaker:0),SpeakerTurn(startMS:1000,endMS:2000,speaker:1),
        SpeakerTurn(startMS:20000,endMS:30000,speaker:0),SpeakerTurn(startMS:50000,endMS:60000,speaker:0)]
    let exclusive = ReidentificationPolicy.exclusiveFlags(referenceTurns)
    try check(exclusive == [false,false,true,true],"Overlapping reference accepted")
    let references = ReidentificationPolicy.references(referenceTurns,exclusive:exclusive)
    try check(references.count == 2 && references.allSatisfy({$0.startMS >= 21000}),"Invalid reference selection")
    print("PASS: Community-1 turn validation, returning speakers, overlap, cache identity/corruption, conservative speaker re-identification")
} catch { fputs("FAIL: \(error)\n",stderr); exit(1) }
