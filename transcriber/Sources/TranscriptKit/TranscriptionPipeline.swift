import Foundation

/// All stages are direct children of the app and share one sticky cancellation token.
public enum TranscriptionPipeline {
    public static func run(runner: ProcessRunner, nativeHelper: URL, diarizerHelper: URL,
                           prepareArguments: [String], directory: URL, modelDirectory: String,
                           manifest: String, cacheDirectory: URL, alignmentModel: String? = nil,
                           onProgress: @escaping @Sendable (WorkerProgress) -> Void) async throws {
        defer { cleanup(directory) }
        try await runner.run(executable:nativeHelper,arguments:prepareArguments,
                             log:directory.appendingPathComponent("prepare.log"),onProgress:onProgress)
        if let alignmentModel {
            try await runner.run(executable:nativeHelper,arguments:["--align",directory.path,alignmentModel],
                log:directory.appendingPathComponent("alignment.log"),onProgress:onProgress)
        }
        try await runner.run(executable:diarizerHelper,arguments:["--attempt-dir",directory.path,
            "--model-dir",modelDirectory,"--model-manifest",manifest,"--cache-dir",cacheDirectory.path],
            log:directory.appendingPathComponent("diarization.log"),onProgress:onProgress)
        try await runner.run(executable:nativeHelper,arguments:["--finalize",directory.path],
                             log:directory.appendingPathComponent("finalize.log"),onProgress:onProgress)
    }
    public static func cleanup(_ directory: URL) {
        for name in ["audio.f32","words.json","prepared.json","turns.json"] {
            try? FileManager.default.removeItem(at:directory.appendingPathComponent(name))
        }
    }
}
