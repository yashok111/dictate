import Foundation
import CryptoKit

struct PipelineError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
func regularData(_ url: URL, limit: Int) throws -> Data {
    let info = try FileManager.default.attributesOfItem(atPath:url.path)
    guard info[.type] as? FileAttributeType == .typeRegular,
          let size = info[.size] as? NSNumber, size.intValue <= limit else { throw PipelineError("Неверный файл: \(url.lastPathComponent)") }
    let data = try Data(contentsOf:url,options:.mappedIfSafe)
    guard data.count <= limit else { throw PipelineError("Файл слишком велик") }
    return data
}
func atomicJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to:url,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
}
struct PreparedInput: Decodable {
    let schemaVersion: Int
    let sampleRate: Int
    let sampleCount: Int
    let durationMS: Int64
    let pcmFormat: String
    let decodeVersion: Int
    let sourceSHA256: String
    let pcmFile: String
    let wordsFile: String
    let asrModel: String
    static func load(at directory: URL) throws -> (PreparedInput, [Float]) {
        let doc = try JSONDecoder().decode(Self.self,from:regularData(directory.appendingPathComponent("prepared.json"),limit:65536))
        guard doc.schemaVersion == 1, doc.sampleRate == 16000, (0...230400000).contains(doc.sampleCount),
              doc.durationMS == Int64(doc.sampleCount) * 1000 / 16000, doc.pcmFormat == "f32le-mono", doc.decodeVersion == 1,
              doc.pcmFile == "audio.f32", doc.wordsFile == "words.json", !doc.asrModel.isEmpty,
              doc.sourceSHA256.count == 64, doc.sourceSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw PipelineError("Неверный манифест PCM") }
        let bytes = try regularData(directory.appendingPathComponent(doc.pcmFile),limit:921600000)
        guard bytes.count == doc.sampleCount * 4 else { throw PipelineError("Неверный размер PCM") }
        var samples = [Float](repeating:0,count:doc.sampleCount)
        _ = samples.withUnsafeMutableBytes { bytes.copyBytes(to:$0) }
        guard samples.allSatisfy(\.isFinite) else { throw PipelineError("Неверные аудиосэмплы") }
        return (doc,samples)
    }
}
struct ModelLock: Decodable {
    struct File: Decodable { let path: String; let url: URL; let bytes: Int; let sha256: String }
    let schemaVersion: Int
    let engine: String
    let sdkRevision: String
    let modelRevision: String
    let modelManifestSHA256: String
    let files: [File]
    static func load(_ url: URL, directory: URL) throws -> Self {
        let lock = try JSONDecoder().decode(Self.self,from:regularData(url,limit:1048576))
        guard lock.schemaVersion == 1, lock.engine == "community-1-fluidaudio", !lock.files.isEmpty,
              lock.sdkRevision == "04e363c29d9a754022d602d6fe1468ab80a0f705" else { throw PipelineError("Неверная версия моделей") }
        let canonical = lock.files.sorted { $0.path < $1.path }.map { "\($0.path)\t\($0.bytes)\t\($0.sha256)\n" }.joined()
        guard digest(Data(canonical.utf8)) == lock.modelManifestSHA256,
              Set(lock.files.map(\.path)).count == lock.files.count else { throw PipelineError("Неверный манифест моделей") }
        for file in lock.files {
            let parts = file.path.split(separator:"/",omittingEmptySubsequences:false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), file.bytes > 0 else { throw PipelineError("Неверный путь модели") }
            var parent = directory
            for part in parts.dropLast() {
                parent.appendPathComponent(String(part))
                guard try FileManager.default.attributesOfItem(atPath:parent.path)[.type] as? FileAttributeType == .typeDirectory else { throw PipelineError("Неверный каталог модели") }
            }
            let bytes = try regularData(directory.appendingPathComponent(file.path),limit:file.bytes)
            guard bytes.count == file.bytes, digest(bytes) == file.sha256 else { throw PipelineError("Повреждён комплект Community-1") }
        }
        return lock
    }
}
