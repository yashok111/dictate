import Foundation
import CryptoKit

public struct ModelError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ModelBundleFile: Codable, Sendable {
    public var path: String
    public var url: URL
    public var bytes: Int64
    public var sha256: String
    public init(path: String, url: URL, bytes: Int64, sha256: String) {
        self.path = path; self.url = url; self.bytes = bytes; self.sha256 = sha256
    }
    public static func manifestDigest(_ files: [Self]) -> String {
        let value = files.sorted { $0.path < $1.path }.map { "\($0.path)\t\($0.bytes)\t\($0.sha256)\n" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ModelArtifact: Codable, Sendable {
    public var id: String
    public var version: String
    public var url: URL
    public var downloadBytes: Int64
    public var downloadSHA256: String
    public var filename: String
    public var installedBytes: Int64
    public var installedSHA256: String
    public var archiveMember: String?
    public var attributionURLs: [URL]
    public var bundleFiles: [ModelBundleFile]? = nil

    public func leafArtifact(_ index: Int) -> ModelArtifact {
        let file = bundleFiles![index]
        var leaf = self
        leaf.id = id + "-leaf-" + String(index); leaf.url = file.url
        leaf.filename = "leaf"; leaf.bundleFiles = nil
        leaf.downloadBytes = file.bytes; leaf.installedBytes = file.bytes
        leaf.downloadSHA256 = file.sha256; leaf.installedSHA256 = file.sha256
        return leaf
    }
}

public struct CatalogProfile: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var asrArtifactID: String
    public var requiredArtifactIDs: [String]
    public var peakBytes: UInt64
    public var rank: Int32
    public var automatic: Bool
}

public struct ModelCatalog: Codable, Sendable {
    public var schemaVersion: Int
    public var artifacts: [ModelArtifact]
    public var profiles: [CatalogProfile]

    public static func load(from url: URL) throws -> ModelCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        func safe(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 180 && value != "." && value != ".." &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
        }
        func digest(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard schemaVersion == 1, !artifacts.isEmpty, !profiles.isEmpty,
              Set(artifacts.map(\.id)).count == artifacts.count,
              Set(profiles.map(\.id)).count == profiles.count else {
            throw ModelError("Некорректный каталог моделей.")
        }
        for artifact in artifacts {
            guard safe(artifact.id), safe(artifact.version), safe(artifact.filename),
                  artifact.url.scheme == "https", artifact.url.host != nil,
                  artifact.url.user == nil, artifact.url.password == nil,
                  artifact.downloadBytes > 0, artifact.installedBytes > 0,
                  artifact.downloadBytes < 100_000_000_000, artifact.installedBytes < 100_000_000_000,
                  digest(artifact.downloadSHA256), digest(artifact.installedSHA256) else {
                throw ModelError("Некорректное описание модели: \(artifact.id).")
            }
            if let files = artifact.bundleFiles {
                guard !files.isEmpty, files.count <= 1000, artifact.archiveMember == nil,
                      Set(files.map(\.path)).count == files.count,
                      files.allSatisfy({ file in
                          file.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safe(String($0)) } &&
                          file.url.scheme == "https" && file.url.host != nil && file.url.user == nil && file.url.password == nil &&
                          file.bytes > 0 && file.bytes < 100_000_000_000 && digest(file.sha256)
                      }), files.reduce(Int64(0), { $0 + $1.bytes }) == artifact.installedBytes,
                      ModelBundleFile.manifestDigest(files) == artifact.installedSHA256 else {
                    throw ModelError("Некорректный комплект файлов модели.")
                }
                let paths = Set(files.map(\.path))
                for file in files {
                    let parts = file.path.split(separator: "/")
                    for count in 1..<parts.count where paths.contains(parts.prefix(count).joined(separator: "/")) {
                        throw ModelError("Конфликт путей модели.")
                    }
                }
            }
            if let member = artifact.archiveMember {
                guard !member.hasPrefix("/"), member.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ safe(String($0)) }) else {
                    throw ModelError("Некорректный путь в архиве модели.")
                }
            } else if artifact.downloadBytes != artifact.installedBytes || artifact.downloadSHA256 != artifact.installedSHA256 {
                throw ModelError("Несогласованные параметры файла модели.")
            }
        }
        let known = Set(artifacts.map(\.id))
        for profile in profiles {
            let required = Set(profile.requiredArtifactIDs)
            guard safe(profile.id), !profile.title.isEmpty, profile.peakBytes > 0,
                  required.count == profile.requiredArtifactIDs.count,
                  required.contains(profile.asrArtifactID), required.isSubset(of: known),
                  Set(["silero", "community-1"]).isSubset(of: required) else {
                throw ModelError("Некорректный комплект модели: \(profile.id).")
            }
        }
    }

    public func requiredArtifacts(for profileID: String) throws -> [ModelArtifact] {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            throw ModelError("Неизвестная модель.")
        }
        return try profile.requiredArtifactIDs.map { id in
            guard let artifact = artifacts.first(where: { $0.id == id }) else {
                throw ModelError("В каталоге отсутствует файл модели.")
            }
            return artifact
        }
    }
}
