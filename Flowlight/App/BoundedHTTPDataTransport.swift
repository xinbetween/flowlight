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

    private final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func install(_ task: URLSessionTask, cancel: (Int) -> Void) {
            lock.lock()
            if cancelled {
                lock.unlock()
                cancel(task.taskIdentifier)
                task.cancel()
                return
            }
            self.task = task
            lock.unlock()
        }

        func cancel(_ finish: (Int) -> Void) {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            guard let task else { return }
            finish(task.taskIdentifier)
            task.cancel()
        }
    }

    private let maximumBytes: Int
    private let allowedOrigin: URL
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    init(allowedOrigin: URL, maximumBytes: Int, requestTimeout: TimeInterval = 20,
         resourceTimeout: TimeInterval = 30, protocolClasses: [AnyClass]? = nil) {
        self.allowedOrigin = allowedOrigin
        self.maximumBytes = maximumBytes
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses ?? configuration.protocolClasses
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                pending[task.taskIdentifier] = Pending(continuation: continuation)
                lock.unlock()
                handle.install(task) { [weak self] taskID in
                    self?.finish(taskID: taskID, result: .failure(CancellationError()))
                }
                task.resume()
            }
        } onCancel: {
            handle.cancel { [weak self] taskID in
                self?.finish(taskID: taskID, result: .failure(CancellationError()))
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
