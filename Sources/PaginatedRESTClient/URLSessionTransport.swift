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

    // `nonisolated` so network actors and background containers can construct the
    // default transport without hopping to MainActor.
    public nonisolated init(
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
        let urlRequest = try Self.urlRequest(from: request)
        #if os(Linux)
        return try await BoundedURLSessionLoader(
            successResponseLimit: successResponseLimit,
            errorResponseLimit: errorResponseLimit,
            requestURL: urlRequest.url,
            bodyFileURL: request.bodyFileURL,
            forwardingDelegate: session.delegate
        ).load(
            configuration: session.configuration,
            delegateQueue: session.delegateQueue,
            request: urlRequest
        )
        #else
        let redirectDelegate = SameOriginRedirectDelegate(
            requestURL: urlRequest.url,
            bodyFileURL: request.bodyFileURL,
            forwardingDelegate: session.delegate
        )
        let (bytes, response) = try await session.bytes(for: urlRequest, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else {
            // A non-HTTP response is a transport-level anomaly; surface it as a URLError
            // so the paginator routes it through the error mapping's `network(_:)` case.
            throw URLError(.badServerResponse)
        }
        let limit = (200 ..< 300).contains(http.statusCode) ? successResponseLimit : errorResponseLimit
        let declared = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        guard declared.map({ $0 <= Int64(limit) }) ?? true else {
            throw RESTResponseTooLargeError(
                statusCode: http.statusCode,
                limit: limit,
                phase: .headers,
                declaredContentLength: declared,
                observedByteCount: 0
            )
        }

        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < limit else {
                throw RESTResponseTooLargeError(
                    statusCode: http.statusCode,
                    limit: limit,
                    phase: .body,
                    declaredContentLength: declared,
                    observedByteCount: data.count
                )
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
    private nonisolated static func urlRequest(from request: RESTRequest) throws -> URLRequest {
        guard request.body == nil || request.bodyFileURL == nil else {
            throw RESTRequestBodyError.multipleSources
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        if let bodyFileURL = request.bodyFileURL {
            try Self.attachFileBody(bodyFileURL, to: &urlRequest)
        } else {
            urlRequest.httpBody = request.body
        }
        return urlRequest
    }

    /// Opens the body file for size validation, then attaches a fresh unopened stream.
    /// URLSession opens and may replay `httpBodyStream` itself; a pre-opened stream is unsafe.
    private nonisolated static func attachFileBody(
        _ bodyFileURL: URL,
        to urlRequest: inout URLRequest
    ) throws {
        guard bodyFileURL.isFileURL else {
            throw RESTRequestBodyError.bodyFileMustBeFileURL(bodyFileURL)
        }
        // Open a short-lived handle to prove the path is readable and to read size from the
        // same open, then close it before handing URLSession an unopened stream.
        guard let probe = InputStream(url: bodyFileURL) else {
            throw RESTRequestBodyError.unreadableBodyFile(bodyFileURL)
        }
        probe.open()
        let probeFailed = probe.streamStatus == .error
        probe.close()
        guard !probeFailed else {
            throw RESTRequestBodyError.unreadableBodyFile(bodyFileURL)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: bodyFileURL.path)
        } catch {
            throw RESTRequestBodyError.unreadableBodyFile(bodyFileURL)
        }
        guard let sizeNumber = attributes[.size] as? NSNumber else {
            throw RESTRequestBodyError.unreadableBodyFile(bodyFileURL)
        }
        let fileSize = sizeNumber.intValue
        if let declared = urlRequest.value(forHTTPHeaderField: "Content-Length") {
            guard declared == String(fileSize) else {
                throw RESTRequestBodyError.contentLengthMismatch(expected: fileSize, declared: declared)
            }
        } else {
            urlRequest.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        }
        guard let stream = InputStream(url: bodyFileURL) else {
            throw RESTRequestBodyError.unreadableBodyFile(bodyFileURL)
        }
        urlRequest.httpBodyStream = stream
    }
}

/// When a response overflow was detected relative to the configured byte ceiling.
public nonisolated enum RESTResponseOverflowPhase: String, Sendable, Equatable {
    /// `Content-Length` (or equivalent) declared a body larger than the limit.
    case headers
    /// Streaming body bytes crossed the limit after headers were accepted.
    case body
}

/// A response exceeded the configured byte ceiling while headers or body bytes were
/// arriving. Direct ``RESTTransport`` consumers can use these facts to map the failure
/// into their own domain error; ``PaginatedRESTClient`` maps success-status overflows
/// through ``RESTTransportErrorMapping/decode(_:)`` and non-success overflows through
/// ``RESTTransportErrorMapping/http(status:body:)``.
public nonisolated struct RESTResponseTooLargeError: Error, Equatable, Sendable {
    /// HTTP status from the response whose body exceeded its applicable limit.
    public let statusCode: Int
    /// The configured maximum number of response-body bytes.
    public let limit: Int
    /// Whether the overflow was detected from declared length or while streaming.
    public let phase: RESTResponseOverflowPhase
    /// Server-declared body length when known (`Content-Length`); `nil` if chunked/unknown.
    public let declaredContentLength: Int64?
    /// Bytes observed before rejection (0 for a headers-phase rejection).
    public let observedByteCount: Int

    public nonisolated init(
        statusCode: Int,
        limit: Int,
        phase: RESTResponseOverflowPhase,
        declaredContentLength: Int64? = nil,
        observedByteCount: Int = 0
    ) {
        self.statusCode = statusCode
        self.limit = limit
        self.phase = phase
        self.declaredContentLength = declaredContentLength
        self.observedByteCount = observedByteCount
    }
}

#if os(Linux)
final class BoundedURLSessionLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
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
        bodyFileURL: URL?,
        forwardingDelegate: (any URLSessionDelegate)?
    ) {
        self.successResponseLimit = successResponseLimit
        self.errorResponseLimit = errorResponseLimit
        redirectDelegate = SameOriginRedirectDelegate(
            requestURL: requestURL,
            bodyFileURL: bodyFileURL,
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
        let declared = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        guard declared.map({ $0 <= Int64(limit) }) ?? true else {
            completionHandler(.cancel)
            complete(.failure(RESTResponseTooLargeError(
                statusCode: http.statusCode,
                limit: limit,
                phase: .headers,
                declaredContentLength: declared,
                observedByteCount: 0
            )))
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
                let declared = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
                return .overflow(RESTResponseTooLargeError(
                    statusCode: response.statusCode,
                    limit: state.limit,
                    phase: .body,
                    declaredContentLength: declared,
                    observedByteCount: state.data.count
                ))
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

extension BoundedURLSessionLoader {
    // Intentionally do not forward `urlSession(_:didBecomeInvalidWithError:)`.
    // This loader owns a per-request session; telling the caller's delegate that *their*
    // session was invalidated would tear down shared networking after one request.

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
        redirectDelegate.urlSession(
            session,
            task: task,
            needNewBodyStream: completionHandler
        )
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
