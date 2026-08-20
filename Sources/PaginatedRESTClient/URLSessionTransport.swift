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

/// A `RESTTransport` backed by `URLSession`. By default it owns an ephemeral session, so
/// cookies and cached responses are not shared with the app's default session. Pass a
/// configured session (custom timeouts or a stub `URLProtocol`) when you need one.
public struct URLSessionTransport: RESTTransport {
    nonisolated let session: URLSession
    nonisolated let successResponseLimit: Int
    nonisolated let errorResponseLimit: Int

    // `nonisolated` so network actors and background containers can construct the
    // default transport without hopping to MainActor.
    public nonisolated init(
        session: URLSession = URLSession(configuration: .ephemeral),
        successResponseLimit: Int = 10 * 1024 * 1024,
        errorResponseLimit: Int = 64 * 1024
    ) {
        self.session = session
        // Limits commonly come from user configuration. A negative value must not crash
        // the host process; treating it as zero is the safest bounded interpretation.
        self.successResponseLimit = max(0, successResponseLimit)
        self.errorResponseLimit = max(0, errorResponseLimit)
    }

    /// Background configurations cannot drive this transport's in-process data-task
    /// response path. Reject them before a request starts rather than failing after the
    /// system has accepted the transfer.
    public nonisolated static func supports(_ session: URLSession) -> Bool {
        #if os(Linux)
        true
        #else
        !session.configuration.sessionSendsLaunchEvents
        #endif
    }

    public nonisolated func data(for request: RESTRequest) async throws -> (Data, Int) {
        let response = try await response(for: request)
        return (response.data, response.statusCode)
    }

    public nonisolated func response(for request: RESTRequest) async throws -> RESTResponse {
        try await load(request, retainingSuccessBody: true)
    }

    public nonisolated func responseDiscardingSuccessBody(
        for request: RESTRequest
    ) async throws -> RESTResponse {
        try await load(request, retainingSuccessBody: false)
    }

    private nonisolated func load(
        _ request: RESTRequest,
        retainingSuccessBody: Bool
    ) async throws -> RESTResponse {
        guard Self.supports(session) else {
            throw RESTRequestError.unsupportedBackgroundSession
        }
        let bodyFileURL = request.bodyFileURL
        let failureBox = FileBodyStreamFailureBox()
        let urlRequest = try Self.urlRequest(from: request, bodyStreamFailureBox: failureBox)
        // Apple uses a task-specific delegate on the supplied session so pooling and
        // session identity match direct URLSession use. Linux creates a one-shot
        // session (FoundationNetworking does not deliver task-specific delegates) from
        // the caller's configuration. Body bytes arrive in `didReceive data` chunks
        // rather than one AsyncBytes element at a time.
        do {
            return try await BoundedURLSessionLoader(
                successResponseLimit: successResponseLimit,
                errorResponseLimit: errorResponseLimit,
                requestURL: urlRequest.url,
                bodyFileURL: bodyFileURL,
                bodyStreamFailureBox: failureBox,
                requiresSameOrigin: Self.requiresSameOrigin(urlRequest, bodyFileURL: bodyFileURL),
                retainingSuccessBody: retainingSuccessBody,
                forwardingDelegate: session.delegate
            ).load(on: session, request: urlRequest)
        } catch let error as RESTRequestBodyError {
            throw error
        } catch {
            if let bodyFileURL, failureBox.failed || Self.isFileBodyTransportError(error) {
                throw RESTRequestBodyError.unreadableBodyFile(bodyFileURL)
            }
            throw error
        }
    }

    /// URLSession often surfaces mid-request file-body I/O as generic transport failures.
    nonisolated static func isFileBodyTransportError(_ error: any Error) -> Bool {
        let urlError = error as? URLError ?? (error as NSError).userInfo[NSUnderlyingErrorKey] as? URLError
        guard let urlError else {
            // Cocoa file I/O sometimes arrives as NSError without a URLError wrapper.
            let nsError = error as NSError
            return nsError.domain == NSCocoaErrorDomain
                && [
                    NSFileReadNoPermissionError,
                    NSFileReadNoSuchFileError,
                    NSFileReadUnknownError,
                    NSFileReadCorruptFileError
                ].contains(nsError.code)
        }
        switch urlError.code {
        case .cannotOpenFile, .fileDoesNotExist, .noPermissionsToReadFile,
             .fileIsDirectory, .dataLengthExceedsMaximum:
            return true
        default:
            return false
        }
    }

    /// Translates the backend-neutral `RESTRequest` into a `URLRequest`.
    private nonisolated static func urlRequest(
        from request: RESTRequest,
        bodyStreamFailureBox: FileBodyStreamFailureBox? = nil
    ) throws -> URLRequest {
        try request.validate()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for field in request.headerFields {
            // `addValue` preserves repeated fields; `setValue` would collapse them (#135).
            urlRequest.addValue(field.value, forHTTPHeaderField: field.name)
        }
        if let bodyFileURL = request.bodyFileURL {
            try Self.attachFileBody(bodyFileURL, to: &urlRequest, failureBox: bodyStreamFailureBox)
        } else {
            urlRequest.httpBody = request.body
        }
        return urlRequest
    }

    private nonisolated static func requiresSameOrigin(
        _ request: URLRequest,
        bodyFileURL: URL?
    ) -> Bool {
        guard bodyFileURL == nil else { return true }
        let sensitive = ["authorization", "cookie", "proxy-authorization"]
        return (request.allHTTPHeaderFields ?? [:]).keys.contains {
            sensitive.contains($0.lowercased())
        }
    }

    /// Opens the body file for size validation, then attaches a fresh unopened stream.
    /// URLSession opens and may replay `httpBodyStream` itself; a pre-opened stream is unsafe.
    private nonisolated static func attachFileBody(
        _ bodyFileURL: URL,
        to urlRequest: inout URLRequest,
        failureBox: FileBodyStreamFailureBox? = nil
    ) throws {
        // Reserved for future stream-monitoring hooks; replay failures use the box via redirects.
        _ = failureBox
        guard bodyFileURL.isFileURL else {
            throw RESTRequestBodyError.bodyFileMustBeFileURL(bodyFileURL)
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
        // `attributesOfItem` follows symlinks, intentionally allowing a symlink to a
        // regular readable file while rejecting directories, devices, and other streams.
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RESTRequestBodyError.unreadableBodyFile(bodyFileURL)
        }
        // Open a short-lived handle to prove the regular file is readable, then close it
        // before handing URLSession an unopened stream.
        guard let probe = InputStream(url: bodyFileURL) else {
            throw RESTRequestBodyError.unreadableBodyFile(bodyFileURL)
        }
        probe.open()
        let probeFailed = probe.streamStatus == .error
        probe.close()
        guard !probeFailed else {
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
        // Monitoring wrapper records open/read failures so the loader can remap them
        // away from opaque network errors after the task completes (#141).
        urlRequest.httpBodyStream = stream
    }

    /// Uses HTTPURLResponse's string accessor instead of debug descriptions of bridged
    /// values (such as NSArray), which can add quotes and brackets not present on the wire.
    /// Package-visible so the Linux bounded loader can reuse the same header projection.
    nonisolated static func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            guard let name = field.key as? String,
                  let value = response.value(forHTTPHeaderField: name)
            else { return }
            result[name] = value
        }
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

/// Collects a bounded response body through `URLSessionDataDelegate` chunk callbacks on the
/// caller's session. Used on every platform so Apple avoids byte-at-a-time `AsyncBytes`
/// appends and Linux preserves connection pooling / session identity.
/// Shared flag set when a file body stream fails after preflight (#141).
nonisolated final class FileBodyStreamFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _failed = false
    nonisolated var failed: Bool {
        lock.withLock { _failed }
    }
    nonisolated func markFailed() {
        lock.withLock { _failed = true }
    }
}

final class BoundedURLSessionLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<RESTResponse, any Error>?
        /// Linux-only owned session. swift-corelibs-foundation does not deliver
        /// task-specific delegates, so Linux creates a one-shot session with `self`
        /// as the session delegate and finishes it when the transfer ends.
        var ownedSession: URLSession?
        var task: URLSessionDataTask?
        var response: HTTPURLResponse?
        var data = Data()
        var limit = 0
        var completed = false
        var cancelled = false
        var retainBody = true
    }

    private struct CancellationResources {
        let continuation: CheckedContinuation<RESTResponse, any Error>?
        let task: URLSessionDataTask?
        let ownedSession: URLSession?
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
    private let retainingSuccessBody: Bool
    private let forwardingDelegate: (any URLSessionDelegate)?
    private let bodyFileURL: URL?
    private let bodyStreamFailureBox: FileBodyStreamFailureBox?

    init(
        successResponseLimit: Int,
        errorResponseLimit: Int,
        requestURL: URL?,
        bodyFileURL: URL?,
        bodyStreamFailureBox: FileBodyStreamFailureBox? = nil,
        requiresSameOrigin: Bool = true,
        retainingSuccessBody: Bool = true,
        forwardingDelegate: (any URLSessionDelegate)?
    ) {
        self.successResponseLimit = successResponseLimit
        self.errorResponseLimit = errorResponseLimit
        self.bodyFileURL = bodyFileURL
        self.bodyStreamFailureBox = bodyStreamFailureBox
        redirectDelegate = SameOriginRedirectDelegate(
            requestURL: requestURL,
            bodyFileURL: bodyFileURL,
            bodyStreamFailureBox: bodyStreamFailureBox,
            requiresSameOrigin: requiresSameOrigin,
            forwardingDelegate: forwardingDelegate
        )
        self.retainingSuccessBody = retainingSuccessBody
        self.forwardingDelegate = forwardingDelegate
    }

    /// Runs `request` through this loader.
    ///
    /// On Apple platforms the loader is attached as a task-specific delegate on the
    /// supplied session so connection pooling and session identity are preserved.
    /// On Linux, task-specific delegates are not delivered by FoundationNetworking, so
    /// the loader creates a one-shot session from the caller's configuration and owns
    /// that session for the duration of the transfer.
    func load(on session: URLSession, request: URLRequest) async throws -> RESTResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !state.cancelled else { return nil }
                    #if os(Linux)
                    let owned = URLSession(
                        configuration: session.configuration,
                        delegate: self,
                        delegateQueue: session.delegateQueue
                    )
                    let task = owned.dataTask(with: request)
                    state.continuation = continuation
                    state.ownedSession = owned
                    state.task = task
                    return task
                    #else
                    let task = session.dataTask(with: request)
                    state.continuation = continuation
                    state.task = task
                    return task
                    #endif
                }
                guard let task else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                #if !os(Linux)
                // Task-specific delegate receives data/redirect callbacks while still using
                // the caller's session (pooling, identity, and invalidation).
                task.delegate = self
                #endif
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    /// The bounded loader only completes data-task transfers. Caller dispositions other than
    /// `.allow` / `.cancel` (for example `.becomeDownload` / `.becomeStream`) are coerced to
    /// `.allow` so a `RESTResponse` can still be produced.
    nonisolated static func constrainedResponseDisposition(
        _ disposition: URLSession.ResponseDisposition
    ) -> URLSession.ResponseDisposition {
        disposition == .cancel ? .cancel : .allow
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
        let retainBody = retainingSuccessBody || !(200 ..< 300).contains(http.statusCode)
        // HEAD is explicitly bodyless. Its Content-Length describes the corresponding GET
        // representation, rather than bytes transferred by this response.
        let declared = dataTask.originalRequest?.httpMethod == "HEAD" || !retainBody ? nil : (
            http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        )
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
            state.retainBody = retainBody
            if retainBody, http.expectedContentLength > 0 {
                state.data.reserveCapacity(Int(http.expectedContentLength))
            }
        }

        let finish: @Sendable (URLSession.ResponseDisposition) -> Void = { disposition in
            completionHandler(Self.constrainedResponseDisposition(disposition))
        }
        guard let delegate = forwardingDelegate as? any URLSessionDataDelegate else {
            finish(.allow)
            return
        }
        #if canImport(FoundationNetworking)
        delegate.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: finish)
        #else
        let forwarded: Void? = delegate.urlSession?(
            session,
            dataTask: dataTask,
            didReceive: response,
            completionHandler: finish
        )
        if forwarded == nil {
            finish(.allow)
        }
        #endif
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldRetain = lock.withLock { state.retainBody }
        guard shouldRetain else {
            forwardDidReceiveData(session, dataTask: dataTask, data: data)
            return
        }
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
            forwardDidReceiveData(session, dataTask: dataTask, data: data)
        case let .overflow(error):
            dataTask.cancel()
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        #if canImport(FoundationNetworking)
        (forwardingDelegate as? any URLSessionTaskDelegate)?
            .urlSession(session, task: task, didCompleteWithError: error)
        #else
        (forwardingDelegate as? any URLSessionTaskDelegate)?
            .urlSession?(session, task: task, didCompleteWithError: error)
        #endif
        if let error {
            if let bodyFileURL,
               bodyStreamFailureBox?.failed == true || URLSessionTransport.isFileBodyTransportError(error) {
                complete(.failure(RESTRequestBodyError.unreadableBodyFile(bodyFileURL)))
            } else {
                complete(.failure(error))
            }
            return
        }
        if let bodyFileURL, bodyStreamFailureBox?.failed == true {
            complete(.failure(RESTRequestBodyError.unreadableBodyFile(bodyFileURL)))
            return
        }
        let result = lock.withLock { () -> RESTResponse? in
            guard let response = state.response else { return nil }
            let headers = URLSessionTransport.responseHeaders(from: response)
            return RESTResponse(
                data: state.data,
                statusCode: response.statusCode,
                headers: headers,
                url: response.url
            )
        }
        complete(result.map(Result.success) ?? .failure(URLError(.badServerResponse)))
    }

    private func forwardDidReceiveData(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        data: Data
    ) {
        #if canImport(FoundationNetworking)
        (forwardingDelegate as? any URLSessionDataDelegate)?
            .urlSession(session, dataTask: dataTask, didReceive: data)
        #else
        (forwardingDelegate as? any URLSessionDataDelegate)?
            .urlSession?(session, dataTask: dataTask, didReceive: data)
        #endif
    }

    private func cancel() {
        let resources = lock.withLock { () -> CancellationResources in
            state.cancelled = true
            guard !state.completed else {
                return CancellationResources(continuation: nil, task: nil, ownedSession: nil)
            }
            state.completed = true
            let result = CancellationResources(
                continuation: state.continuation,
                task: state.task,
                ownedSession: state.ownedSession
            )
            state.continuation = nil
            state.task = nil
            state.ownedSession = nil
            return result
        }
        resources.task?.cancel()
        resources.ownedSession?.invalidateAndCancel()
        resources.continuation?.resume(throwing: CancellationError())
    }

    private func complete(_ result: Result<RESTResponse, any Error>) {
        let resources = lock.withLock { () -> (CheckedContinuation<RESTResponse, any Error>?, URLSession?) in
            guard !state.completed else { return (nil, nil) }
            state.completed = true
            let pair = (state.continuation, state.ownedSession)
            state.continuation = nil
            state.task = nil
            state.ownedSession = nil
            return pair
        }
        // Only Linux owns a per-request session; never invalidate the caller's session.
        resources.1?.finishTasksAndInvalidate()
        resources.0?.resume(with: result)
    }
}

extension BoundedURLSessionLoader {
    // Intentionally do not forward `urlSession(_:didBecomeInvalidWithError:)`.
    // The loader never owns the caller's session; invalidation belongs to the session owner.

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        redirectDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
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
        redirectDelegate.urlSession(
            session,
            task: task,
            didReceive: challenge,
            completionHandler: completionHandler
        )
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
        redirectDelegate.urlSession(
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
        redirectDelegate.urlSession(
            session,
            task: task,
            willBeginDelayedRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        redirectDelegate.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    #if !canImport(FoundationNetworking)
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        redirectDelegate.urlSession(session, taskIsWaitingForConnectivity: task)
    }

    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceiveInformationalResponse response: HTTPURLResponse
    ) {
        redirectDelegate.urlSession(session, task: task, didReceiveInformationalResponse: response)
    }
    #endif

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
        #if canImport(FoundationNetworking)
        delegate.urlSession(
            session,
            dataTask: dataTask,
            willCacheResponse: proposedResponse,
            completionHandler: completionHandler
        )
        #else
        let forwarded: Void? = delegate.urlSession?(
            session,
            dataTask: dataTask,
            willCacheResponse: proposedResponse,
            completionHandler: completionHandler
        )
        if forwarded == nil {
            completionHandler(proposedResponse)
        }
        #endif
    }
}
