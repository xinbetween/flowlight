import Foundation

final class BoundedHTTPDataTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum TransportError: Error, Equatable {
        case redirectRejected
        case responseTooLarge
        case invalidResponse
    }

    private struct Pending {
        var response: URLResponse?
        var data = Data()
        var continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    private let maximumBytes: Int
    private let allowedOrigin: URL
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    init(allowedOrigin: URL, maximumBytes: Int, requestTimeout: TimeInterval = 20,
         resourceTimeout: TimeInterval = 30) {
        self.allowedOrigin = allowedOrigin
        self.maximumBytes = maximumBytes
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                pending[task.taskIdentifier] = Pending(continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            let taskIDs = Set(self.pending.keys)
            self.lock.unlock()
            self.session.getAllTasks { tasks in
                for task in tasks where taskIDs.contains(task.taskIdentifier) { task.cancel() }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url.map(sameOrigin) == true else {
            completionHandler(nil)
            finish(taskID: task.taskIdentifier, result: .failure(TransportError.redirectRejected))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, result: .failure(TransportError.responseTooLarge))
            return
        }
        lock.lock()
        if var value = pending[dataTask.taskIdentifier] {
            value.response = response
            pending[dataTask.taskIdentifier] = value
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var value = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        let nextCount = value.data.count + data.count
        guard nextCount <= maximumBytes else {
            lock.unlock()
            dataTask.cancel()
            finish(taskID: dataTask.taskIdentifier, result: .failure(TransportError.responseTooLarge))
            return
        }
        value.data.append(data)
        pending[dataTask.taskIdentifier] = value
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        guard let value = pending.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        lock.unlock()
        if let error { value.continuation.resume(throwing: error); return }
        guard let response = value.response else {
            value.continuation.resume(throwing: TransportError.invalidResponse)
            return
        }
        value.continuation.resume(returning: (value.data, response))
    }

    private func finish(taskID: Int, result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        let value = pending.removeValue(forKey: taskID)
        lock.unlock()
        value?.continuation.resume(with: result)
    }

    private func sameOrigin(_ candidate: URL) -> Bool {
        candidate.scheme?.lowercased() == allowedOrigin.scheme?.lowercased()
            && candidate.host?.lowercased() == allowedOrigin.host?.lowercased()
            && effectivePort(candidate) == effectivePort(allowedOrigin)
    }

    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }
}
