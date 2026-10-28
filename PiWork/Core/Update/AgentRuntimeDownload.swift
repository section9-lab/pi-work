import Foundation

/// A bounded download to disk. The delegate queue serializes all result writes.
private final class AgentRuntimeDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let limit: Int64
    let exactByteCount: Bool
    private let completionLock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var completed: Result<HTTPURLResponse, Error>?
    var result: Result<HTTPURLResponse, Error>?

    init(destination: URL, limit: Int64, exactByteCount: Bool) {
        self.destination = destination
        self.limit = limit
        self.exactByteCount = exactByteCount
    }

    func register(_ continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        completionLock.lock()
        let completed = self.completed
        if completed == nil { self.continuation = continuation }
        completionLock.unlock()
        if let completed { continuation.resume(with: completed) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            result = .failure(AgentRuntimeError.integrity)
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, AgentRuntimeDownload.isTrusted(url) else {
            result = .failure(AgentRuntimeError.integrity)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard result == nil else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw AgentRuntimeError.unavailable
            }
            guard
                  let url = response.url, AgentRuntimeDownload.isTrusted(url),
                  let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value,
                  size <= limit, !exactByteCount || size == limit else { throw AgentRuntimeError.integrity }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(response)
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = result ?? .failure(error ?? AgentRuntimeError.integrity)
        completionLock.lock()
        completed = outcome
        let continuation = self.continuation
        self.continuation = nil
        completionLock.unlock()
        continuation?.resume(with: outcome)
        session.finishTasksAndInvalidate()
    }
}

enum AgentRuntimeDownload {
    static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
            .contains(url.host?.lowercased() ?? "")
    }

    static func fetch(_ request: URLRequest, to destination: URL, byteCount: Int64,
                      exactByteCount: Bool = true,
                      configuration: URLSessionConfiguration) async throws {
        try Task.checkCancellation()
        guard let url = request.url, isTrusted(url), byteCount > 0,
              byteCount <= AgentRuntimeManifest.maximumArchiveBytes else { throw AgentRuntimeError.integrity }
        let delegate = AgentRuntimeDownloadDelegate(destination: destination, limit: byteCount, exactByteCount: exactByteCount)
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        _ = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(continuation)
                task.resume()
            }
        }, onCancel: { task.cancel() })
        try Task.checkCancellation()
    }
}
