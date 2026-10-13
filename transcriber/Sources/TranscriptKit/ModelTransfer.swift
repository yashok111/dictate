import Foundation

public enum TransferEvent: Sendable {
    case progress(received: Int64, total: Int64?)
    case downloaded(URL)
}

public protocol ModelTransfer: AnyObject, Sendable {
    func start(artifact: ModelArtifact, resumeData: Data?, stagingDirectory: URL) -> AsyncThrowingStream<TransferEvent, Error>
    func pause() async -> Data?
}

public final class URLSessionModelTransfer: NSObject, ModelTransfer, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: AsyncThrowingStream<TransferEvent, Error>.Continuation?
    private var artifact: ModelArtifact?
    private var staging: URL?

    public func start(artifact: ModelArtifact, resumeData: Data?, stagingDirectory: URL) -> AsyncThrowingStream<TransferEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); defer { lock.unlock() }
            guard task == nil else { continuation.finish(throwing: ModelError("Загрузка уже запущена.")); return }
            self.artifact = artifact; self.staging = stagingDirectory
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            configuration.urlCache = nil
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            if let resumeData { task = session.downloadTask(withResumeData: resumeData) }
            else {
                var request = URLRequest(url: artifact.url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                task = session.downloadTask(with: request)
            }
            task?.resume()
        }
    }

    public func pause() async -> Data? {
        await withCheckedContinuation { reply in
            lock.lock(); let current = task; lock.unlock()
            guard let current else { reply.resume(returning: nil); return }
            current.cancel { data in reply.resume(returning: data) }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        // Managed catalogs allow HTTPS only. Direct loopback requests are useful
        // to embedders and the fixture server, but cannot redirect off loopback.
        lock.lock(); let origin = artifact?.url; lock.unlock()
        let loopback = origin?.scheme == "http" && ["127.0.0.1", "::1"].contains(origin?.host ?? "") &&
            request.url?.scheme == "http" && request.url?.host == origin?.host && request.url?.port == origin?.port
        completionHandler(request.url?.scheme == "https" || loopback ? request : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let artifact else { return }
        if totalBytesWritten > artifact.downloadBytes || totalBytesExpectedToWrite > artifact.downloadBytes {
            continuation?.finish(throwing: ModelError("Сервер прислал файл неверного размера."))
            downloadTask.cancel()
        } else {
            continuation?.yield(.progress(received: totalBytesWritten,
                total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); defer { lock.unlock() }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode), let staging else {
                throw ModelError("Сервер не отдал файл модели. Повторите загрузку.")
            }
            let destination = staging.appendingPathComponent(UUID().uuidString + ".download")
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            continuation?.yield(.downloaded(destination))
        } catch { continuation?.finish(throwing: error) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error { continuation?.finish(throwing: error) }
        else { continuation?.finish() }
        continuation = nil; self.task = nil; self.session = nil
        session.finishTasksAndInvalidate()
    }
}
