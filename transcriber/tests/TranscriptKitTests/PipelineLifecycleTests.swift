import Foundation
import TranscriptKit

// Old controller fixtures simulate inference; adapt only their subprocess protocol.
func stageTestHelpers(_ native: URL) throws {
    var text = try String(contentsOf:native,encoding:.utf8)
    text = text.replacingOccurrences(of:"output=\"$5\"",with:"output=\"$4/transcript.json\"")
        .replacingOccurrences(of:"> \"$5\"",with:"> \"$4/transcript.json\"")
        .replacingOccurrences(of:"\"$4/transcript.json.preview.json\" \"$5\"",with:"\"$4/transcript.json.preview.json\" \"$4/transcript.json\"")
        .replacingOccurrences(of:"shift 5",with:"shift 4")
    text = text.replacingOccurrences(of:"#!/bin/sh\n",with:"#!/bin/sh\nif [ \"$1\" = --finalize ] || [ \"$1\" = --align ]; then exit 0; fi\n")
    try text.write(to:native,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:native.path)
    let diarizer = native.deletingLastPathComponent().appendingPathComponent("transcriber-diarizer")
    try "#!/bin/sh\nexit 0\n".write(to:diarizer,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:diarizer.path)
}

struct PipelineLifecycleTests {
    func testAlignmentCancellationStopsRemainingStages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let helper = root.appendingPathComponent("helper")
        try """
        #!/bin/sh
        cd "$(dirname "$0")"
        if [ "$1" = --prepare ]; then touch audio.f32 words.json prepared.json; exit 0; fi
        if [ "$1" = --align ]; then
          printf '%s\\n' '{"stage":"aligning","progress":0.1}'
          exec /bin/sleep 20
        fi
        touch unexpected-stage
        """.write(to:helper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let runner = ProcessRunner()
        do {
            try await TranscriptionPipeline.run(runner:runner,nativeHelper:helper,diarizerHelper:helper,
                prepareArguments:["--prepare"],directory:root,modelDirectory:"model",manifest:"manifest",
                cacheDirectory:root,alignmentModel:"alignment") { event in
                    if event.stage == "aligning" { runner.cancel() }
                }
            throw ModelTestFailure(description:"Cancelled alignment completed")
        } catch is CancellationError {}
        try modelCheck(!FileManager.default.fileExists(atPath:root.appendingPathComponent("unexpected-stage").path),"Stage ran after cancellation")
        try modelCheck(!FileManager.default.fileExists(atPath:root.appendingPathComponent("audio.f32").path),"Private PCM retained after cancellation")
    }
    func testCancellationBetweenProcessesIsSticky() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let runner = ProcessRunner()
        try await runner.run(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[],log:root.appendingPathComponent("one"),onProgress:{ _ in })
        runner.cancel()
        let marker = root.appendingPathComponent("must-not-exist")
        do {
            try await runner.run(executable:URL(fileURLWithPath:"/usr/bin/touch"),arguments:[marker.path],log:root.appendingPathComponent("two"),onProgress:{ _ in })
            throw ModelTestFailure(description:"Cancelled pipeline launched next stage")
        } catch is CancellationError {}
        try modelCheck(!FileManager.default.fileExists(atPath:marker.path),"Next stage executed")
    }
}
