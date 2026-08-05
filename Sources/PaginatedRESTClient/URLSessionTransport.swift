//
//  URLSessionTransport.swift
//  PaginatedRESTClient
//
//  The batteries-included default transport, layered over `URLSession`. This is the
//  behaviour the paginator shipped before the transport became pluggable: a plain
//  `URLSession.data(for:)` round-trip. It is Foundation-only, so the core has no
//  third-party dependency and stays Linux-clean.
//

import Foundation
// On Linux, URLSession lives in FoundationNetworking rather than Foundation.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `RESTTransport` backed by `URLSession`. Constructed with `URLSession.shared` by
/// default; pass a configured session (custom timeouts, an ephemeral configuration, a
/// stub `URLProtocol`) when you need one.
public struct URLSessionTransport: RESTTransport {
    nonisolated let session: URLSession
    nonisolated let successResponseLimit: Int
    nonisolated let errorResponseLimit: Int

    public init(
        session: URLSession = .shared,
        successResponseLimit: Int = 10 * 1024 * 1024,
        errorResponseLimit: Int = 64 * 1024
    ) {
        precondition(successResponseLimit >= 0 && errorResponseLimit >= 0, "Response limits must not be negative")
        self.session = session
        self.successResponseLimit = successResponseLimit
        self.errorResponseLimit = errorResponseLimit
    }

    public nonisolated func data(for request: RESTRequest) async throws -> (Data, Int) {
        let response = try await response(for: request)
        return (response.data, response.statusCode)
    }

    public nonisolated func response(for request: RESTRequest) async throws -> RESTResponse {
        let urlRequest = Self.urlRequest(from: request)
        #if os(Linux)
        return try await BoundedURLSessionLoader(
            successResponseLimit: successResponseLimit,
            errorResponseLimit: errorResponseLimit,
            requestURL: urlRequest.url,
            forwardingDelegate: session.delegate
        ).load(
            configuration: session.configuration,
            delegateQueue: session.delegateQueue,
            request: urlRequest
        )
        #else
        let redirectDelegate = SameOriginRedirectDelegate(
            requestURL: urlRequest.url,
            forwardingDelegate: session.delegate
        )
        let (bytes, response) = try await session.bytes(for: urlRequest, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else {
            // A non-HTTP response is a transport-level anomaly; surface it as a URLError
            // so the paginator routes it through the error mapping's `network(_:)` case.
            throw URLError(.badServerResponse)
        }
        let limit = (200 ..< 300).contains(http.statusCode) ? successResponseLimit : errorResponseLimit
        guard http.expectedContentLength < 0 || http.expectedContentLength <= Int64(limit) else {
            throw RESTResponseTooLargeError(statusCode: http.statusCode, limit: limit)
        }

        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < limit else {
                throw RESTResponseTooLargeError(statusCode: http.statusCode, limit: limit)
            }
            data.append(byte)
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            let name = (field.key as? String) ?? String(describing: field.key)
            result[name] = String(describing: field.value)
        }
        return RESTResponse(data: data, statusCode: http.statusCode, headers: headers)
        #endif
    }

    /// Translates the backend-neutral `RESTRequest` into a `URLRequest`.
    private nonisolated static func urlRequest(from request: RESTRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }
}

nonisolated struct RESTResponseTooLargeError: Error, Equatable {
    let statusCode: Int
    let limit: Int
}

#if os(Linux)
private final class BoundedURLSessionLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<RESTResponse, any Error>?
        var session: URLSession?
        var task: URLSessionDataTask?
        var response: HTTPURLResponse?
        var data = Data()
        var limit = 0
        var completed = false
        var cancelled = false
    }

    private struct CancellationResources {
        let continuation: CheckedContinuation<RESTResponse, any Error>?
        let task: URLSessionDataTask?
        let session: URLSession?
    }

    private enum DataReceipt {
        case ignored
        case accepted
        case overflow(RESTResponseTooLargeError)
    }

    private let lock = NSLock()
    private var state = State()
    private let successResponseLimit: Int
    private let errorResponseLimit: Int
    private let redirectDelegate: SameOriginRedirectDelegate
    private let forwardingDelegate: (any URLSessionDelegate)?

    init(
        successResponseLimit: Int,
        errorResponseLimit: Int,
        requestURL: URL?,
        forwardingDelegate: (any URLSessionDelegate)?
    ) {
        self.successResponseLimit = successResponseLimit
        self.errorResponseLimit = errorResponseLimit
        redirectDelegate = SameOriginRedirectDelegate(
            requestURL: requestURL,
            forwardingDelegate: forwardingDelegate
        )
        self.forwardingDelegate = forwardingDelegate
    }

    func load(
        configuration: URLSessionConfiguration,
        delegateQueue: OperationQueue,
        request: URLRequest
    ) async throws -> RESTResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !state.cancelled else { return nil }
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
                    let task = session.dataTask(with: request)
                    state.continuation = continuation
                    state.session = session
                    state.task = task
                    return task
                }
                guard let task else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(.failure(URLError(.badServerResponse)))
            return
        }
        let limit = (200 ..< 300).contains(http.statusCode) ? successResponseLimit : errorResponseLimit
        guard http.expectedContentLength < 0 || http.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel)
            complete(.failure(RESTResponseTooLargeError(statusCode: http.statusCode, limit: limit)))
            return
        }

        lock.withLock {
            guard !state.completed else { return }
            state.response = http
            state.limit = limit
            if http.expectedContentLength > 0 {
                state.data.reserveCapacity(Int(http.expectedContentLength))
            }
        }
        guard let delegate = forwardingDelegate as? any URLSessionDataDelegate else {
            completionHandler(.allow)
            return
        }
        delegate.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
            completionHandler(disposition)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let receipt = lock.withLock { () -> DataReceipt in
            guard !state.completed, let response = state.response else { return .ignored }
            guard data.count <= state.limit - state.data.count else {
                return .overflow(RESTResponseTooLargeError(statusCode: response.statusCode, limit: state.limit))
            }
            state.data.append(data)
            return .accepted
        }
        switch receipt {
        case .ignored:
            break
        case .accepted:
            (forwardingDelegate as? any URLSessionDataDelegate)?
                .urlSession(session, dataTask: dataTask, didReceive: data)
        case let .overflow(error):
            dataTask.cancel()
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        (forwardingDelegate as? any URLSessionTaskDelegate)?
            .urlSession(session, task: task, didCompleteWithError: error)
        if let error {
            complete(.failure(error))
            return
        }
        let result = lock.withLock { () -> RESTResponse? in
            guard let response = state.response else { return nil }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
                let name = (field.key as? String) ?? String(describing: field.key)
                result[name] = String(describing: field.value)
            }
            return RESTResponse(data: state.data, statusCode: response.statusCode, headers: headers)
        }
        complete(result.map(Result.success) ?? .failure(URLError(.badServerResponse)))
    }

    private func cancel() {
        let resources = lock.withLock { () -> CancellationResources in
            state.cancelled = true
            guard !state.completed else {
                return CancellationResources(continuation: nil, task: nil, session: nil)
            }
            state.completed = true
            let result = CancellationResources(
                continuation: state.continuation,
                task: state.task,
                session: state.session
            )
            state.continuation = nil
            state.task = nil
            state.session = nil
            return result
        }
        resources.task?.cancel()
        resources.session?.invalidateAndCancel()
        resources.continuation?.resume(throwing: CancellationError())
    }

    private func complete(_ result: Result<RESTResponse, any Error>) {
        let resources = lock.withLock { () -> (CheckedContinuation<RESTResponse, any Error>?, URLSession?) in
            guard !state.completed else { return (nil, nil) }
            state.completed = true
            let result = (state.continuation, state.session)
            state.continuation = nil
            state.task = nil
            state.session = nil
            return result
        }
        resources.1?.finishTasksAndInvalidate()
        resources.0?.resume(with: result)
    }
}

private extension BoundedURLSessionLoader {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let forwardingDelegate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        forwardingDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        redirectDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let delegate = forwardingDelegate as? any URLSessionTaskDelegate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        guard let delegate = forwardingDelegate as? any URLSessionTaskDelegate else {
            completionHandler(nil)
            return
        }
        delegate.urlSession(session, task: task, needNewBodyStream: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        (forwardingDelegate as? any URLSessionTaskDelegate)?.urlSession(
            session,
            task: task,
            didSendBodyData: bytesSent,
            totalBytesSent: totalBytesSent,
            totalBytesExpectedToSend: totalBytesExpectedToSend
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willBeginDelayedRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    ) {
        guard let delegate = forwardingDelegate as? any URLSessionTaskDelegate else {
            completionHandler(.continueLoading, nil)
            return
        }
        delegate.urlSession(
            session,
            task: task,
            willBeginDelayedRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        (forwardingDelegate as? any URLSessionTaskDelegate)?
            .urlSession(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        guard let delegate = forwardingDelegate as? any URLSessionDataDelegate else {
            completionHandler(proposedResponse)
            return
        }
        delegate.urlSession(
            session,
            dataTask: dataTask,
            willCacheResponse: proposedResponse,
            completionHandler: completionHandler
        )
    }
}
#endif
