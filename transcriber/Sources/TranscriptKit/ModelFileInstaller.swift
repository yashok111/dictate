import Foundation
import CryptoKit

enum ModelFileInstaller {
    static func regularFile(_ url: URL) throws -> [FileAttributeKey: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ModelError("Ожидался обычный файл модели.")
        }
        return attributes
    }

    static func verify(_ url: URL, bytes: Int64, digest: String) throws {
        let attributes = try regularFile(url)
        guard (attributes[.size] as? NSNumber)?.int64Value == bytes else {
            throw ModelError("Неверный размер файла модели. Загрузите его заново.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= bytes else { throw ModelError("Размер модели изменился во время проверки.") }
            hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == bytes, actual == digest else {
            throw ModelError("Файл модели повреждён. Загрузите его заново.")
        }
    }

    static func prepare(_ source: URL, artifact: ModelArtifact, directory: URL) throws -> URL {
        try verify(source, bytes: artifact.downloadBytes, digest: artifact.downloadSHA256)
        let destination = directory.appendingPathComponent(artifact.filename)
        if let member = artifact.archiveMember {
            // Listing exactly the selected member catches links and duplicate entries.
            // The pinned archive may contain scripts; none of them are extracted.
            let listing = try tar(["-tvf", source.path, member], limit: 64 * 1024)
            let lines = String(decoding: listing, as: UTF8.self).split(separator: "\n")
            guard lines.count == 1, lines[0].first == "-" else {
                throw ModelError("В архиве нет единственного обычного файла модели.")
            }
            let output = try FileHandle(forWritingTo: createPrivateFile(destination))
            defer { try? output.close() }
            _ = try tar(["-xOf", source.path, member], limit: artifact.installedBytes, output: output)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try verify(destination, bytes: artifact.installedBytes, digest: artifact.installedSHA256)
        return destination
    }

    private static func createPrivateFile(_ url: URL) throws -> URL {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ModelError("Не удалось создать файл модели.")
        }
        return url
    }

    private static func tar(_ arguments: [String], limit: Int64, output: FileHandle? = nil) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? pipe.fileHandleForReading.close() }
        var result = Data(), count: Int64 = 0
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                count += Int64(chunk.count)
                guard count <= limit else { throw ModelError("Распакованная модель превышает ожидаемый размер.") }
                if let output { try output.write(contentsOf: chunk) } else { result.append(chunk) }
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModelError("Не удалось прочитать архив модели.") }
        return result
    }
}
