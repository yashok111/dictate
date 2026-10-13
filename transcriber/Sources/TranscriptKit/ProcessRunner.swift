import Foundation
import Darwin

public struct WorkerProgress: Decodable {
    public let stage: String
    public let progress: Double
}

public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        guard let active, active.isRunning else { return }
        active.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if active.isRunning { kill(active.processIdentifier, SIGKILL) }
        }
    }

    public func forceCancel() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        if let active, active.isRunning { kill(active.processIdentifier, SIGKILL) }
    }

    public func run(executable: URL, arguments: [String], log: URL,
                    onProgress: @escaping @Sendable (WorkerProgress) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let child = Process(); child.executableURL = executable; child.arguments = arguments
                    let pipe = Pipe(); child.standardOutput = pipe
                    FileManager.default.createFile(atPath: log.path, contents: nil,
                                                   attributes: [.posixPermissions: 0o600])
                    let errors = try FileHandle(forWritingTo: log)
                    defer { try? errors.close() }
                    child.standardError = errors
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); throw CancellationError() }
                    do { try child.run(); self.process = child; self.lock.unlock() }
                    catch { self.lock.unlock(); throw error }
                    // Drain continuously, so a full stdout pipe cannot deadlock inference.
                    var pending = Data()
                    while true {
                        let data = pipe.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        pending.append(data)
                        while let end = pending.firstIndex(of: 10) {
                            let line = pending.prefix(upTo: end)
                            if let event = try? JSONDecoder().decode(WorkerProgress.self, from: line),
                               event.progress.isFinite { onProgress(event) }
                            pending.removeSubrange(...end)
                        }
                        // Cap only the leftover PARTIAL line: capping before parsing dropped every
                        // complete progress line a large read had brought in (F074).
                        if pending.count > 65_536 { pending.removeAll() }
                    }
                    child.waitUntilExit()
                    self.lock.lock(); self.process = nil; let wasCancelled = self.cancelled; self.lock.unlock()
                    if wasCancelled { throw CancellationError() }
                    if child.terminationReason == .exit && child.terminationStatus == 3 {
                        throw NSError(domain: "TranscriberWorker", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Не удалось использовать контекст встречи. Нажмите «Повторить», оставьте короткий список нужных имён, названий и терминов и запустите расшифровку снова."])
                    }
                    if child.terminationReason == .exit && child.terminationStatus == 4 {
                        throw ModelError("Комплект Community-1 отсутствует или повреждён. Откройте «Модели…» и загрузите его заново.")
                    }
                    guard child.terminationReason == .exit && child.terminationStatus == 0 else {
                        throw NSError(domain: "TranscriberWorker", code: Int(child.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "Не удалось обработать запись. Проверьте файл и установленные модели."])
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
