//
//  PaginatedRESTClient.swift
//  PaginatedRESTClient
//
//  A generic, domain-free paginator for paginated, bearer-authenticated REST APIs:
//  request building, retry with exponential backoff, concurrent multi-page fetching,
//  and background JSON decoding. The pagination concern is reusable and unit-testable
//  apart from any domain-specific models and endpoints, which compose it.
//
//  The networking backend, decoder, request-body encoder, error mapping, and logger are
//  all injected, so nothing here knows any particular API's HTTP stack, date quirks,
//  model shapes, error type, or logging subsystem. The byte-level networking is hidden
//  behind `RESTTransport` (see `URLSessionTransport` for the default), and failures are
//  built through an injected `RESTTransportErrorMapping` rather than naming a domain
//  error, so the paginator carries no coupling to any one API or HTTP client.
//

import Foundation

// MARK: - Pagination

/// A list response that may span multiple pages. Many REST APIs cap items per page and
/// supply a `next_page` link when more remain. Callers that ignore it silently see only
/// the first page.
///
/// `nextPage` may be an absolute URL or a relative reference (for example `?page=2`).
/// Relative values resolve against the URL of the page that returned them (RFC 3986).
/// Every follow-up URL must stay on the configured HTTP(S) origin before the bearer
/// credential is sent; links that leave that origin are rejected.
///
/// `total` (the count across all pages, when the endpoint reports it) lets the client
/// compute the page count from the first response and fetch the rest concurrently,
/// rather than walking `next_page` one blocking round-trip at a time.

/// A ``Hashable`` & ``Sendable`` item identity for pagination de-duplication (#122).
///
/// Swift 6 marks `AnyHashable`'s `Sendable` conformance unavailable, so the public
/// pagination API cannot return `AnyHashable?` for values that cross task boundaries.
/// This wrapper erases a concrete `Hashable & Sendable` value while remaining usable
/// in `Set` storage on the parallel page path.
public nonisolated struct RESTItemIdentity: Hashable, @unchecked Sendable {
    private let base: AnyHashable

    public nonisolated init<Value: Hashable & Sendable>(_ value: Value) {
        base = AnyHashable(value)
    }
}

public protocol PagedResponse: Decodable, Sendable {
    associatedtype Item: Decodable & Sendable
    // `nonisolated` so the pagination pipeline can read these off the main actor
    // (see `streamAllPages`); without it the module's default MainActor isolation
    // would make the protocol requirements main-actor-isolated.
    nonisolated var pageItems: [Item] { get }
    nonisolated var nextPage: String? { get }
    nonisolated var total: Int? { get }
    /// The number of items a *full* page of this endpoint holds - the page size the client
    /// is asking for, not whatever the first response happened to return.
    ///
    /// The page count on the parallel path is `ceil(total / pageSize)`, so this must not be
    /// smaller than the endpoint's real page size: a first page shortened by server-side
    /// filtering would otherwise *over*-estimate the page count and make the client request
    /// pages that do not exist. Over-estimating this value is safe - the page count comes
    /// out short and `next_page` is walked for the remainder - so the default is a
    /// deliberately conservative 100, which is a common REST default. Declare the endpoint's
    /// actual page size to get the full benefit of the parallel path.
    nonisolated static var pageSize: Int { get }
    /// A stable identity used to de-duplicate items when stitching parallel pages,
    /// so a server that echoes page 1 for an over-requested `page` can't produce
    /// duplicate rows. `nil` opts out (e.g. items with no stable unique id), and
    /// opting out routes the whole list down the sequential `next_page` walk, where
    /// de-duplication isn't needed because no page is ever requested speculatively.
    nonisolated static func identity(of item: Item) -> RESTItemIdentity?
}

public extension PagedResponse {
    nonisolated static var pageSize: Int {
        100
    }

    nonisolated static func identity(of _: Item) -> RESTItemIdentity? {
        nil
    }
}

// MARK: - Error mapping

/// Supplies the transport's failures as the composing client's own error type, so this
/// file names no domain-specific error. The client decides how a missing key, an HTTP
/// status, a decode failure, or a transport-level `URLError` becomes its error, and which
/// already-mapped errors are transient (retry-worthy). Lifting the concrete error out this
/// way is what keeps the transport reusable across APIs.
///
/// `nonisolated` requirements (like `PagedResponse`) so the mapping can be called from the
/// off-main pagination pipeline rather than being pinned to the module's default MainActor
/// isolation.
public protocol RESTTransportErrorMapping: Sendable {
    nonisolated func missingAPIKey() -> Error
    nonisolated func http(status: Int, body: String) -> Error
    nonisolated func decode(_ detail: String) -> Error
    nonisolated func network(_ error: URLError) -> Error
    /// Client-side validation, unsafe URL, or pagination-policy failure (not an HTTP response).
    nonisolated func invalidRequest(_ detail: String) -> Error
    /// Request-body encoding failure raised before the transport runs.
    nonisolated func encode(_ detail: String) -> Error
    /// Whether an error already produced by this mapping should be retried.
    nonisolated func isTransient(_ error: Error) -> Bool
}

public extension RESTTransportErrorMapping {
    /// Defaults to ``decode(_:)`` so existing mappings stay source-compatible while
    /// validation failures stop masquerading as HTTP status zero.
    nonisolated func invalidRequest(_ detail: String) -> Error {
        decode(detail)
    }

    /// Defaults to ``invalidRequest(_:)``.
    nonisolated func encode(_ detail: String) -> Error {
        invalidRequest(detail)
    }
}

// MARK: - Retry coordination

/// Injectable sources used by retry tests. Production cooldowns use monotonic uptime;
/// wall-clock time is retained only for interpreting HTTP dates.
nonisolated struct RetryRuntime: Sendable {
    let now: @Sendable () -> Date
    let monotonicNow: @Sendable () -> TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let jitter: @Sendable () -> Double

    init(
        now: @escaping @Sendable () -> Date,
        monotonicNow: (@Sendable () -> TimeInterval)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        jitter: @escaping @Sendable () -> Double
    ) {
        self.now = now
        self.monotonicNow = monotonicNow ?? { now().timeIntervalSinceReferenceDate }
        self.sleep = sleep
        self.jitter = jitter
    }

    static let live = RetryRuntime(
        now: Date.init,
        monotonicNow: { ProcessInfo.processInfo.systemUptime },
        sleep: { delay in try await Task.sleep(for: .seconds(delay)) },
        jitter: { Double.random(in: 0 ... 1) }
    )
}

/// A client-wide rate-limit deadline. A lock keeps the fast preflight check synchronous
/// while allowing every concurrent pagination task to publish and observe one cooldown.
nonisolated final class RateLimitCooldown: @unchecked Sendable {
    private struct Window {
        var startedAt: TimeInterval
        var deadline: TimeInterval
    }

    private let lock = NSLock()
    private var windows: [String: Window] = [:]

    func extend(
        until candidate: TimeInterval,
        observedAt now: TimeInterval,
        maximumWindow: TimeInterval,
        for key: String
    ) {
        lock.withLock {
            var window = windows[key].flatMap { $0.deadline > now ? $0 : nil }
                ?? Window(startedAt: now, deadline: now)
            let capped = min(candidate, window.startedAt + maximumWindow)
            if capped > window.deadline { window.deadline = capped }
            windows[key] = window
        }
    }

    func remaining(at now: TimeInterval, for key: String) -> TimeInterval? {
        lock.withLock {
            guard let window = windows[key] else { return nil }
            let delay = window.deadline - now
            if delay > 0 { return delay }
            windows[key] = nil
            return nil
        }
    }
}

/// Keeps the mapped client error private while retaining the HTTP response for retry
/// decisions. Public `perform` unwraps this before returning an error to its caller.
private nonisolated struct HTTPAttemptFailure: Error {
    let response: RESTResponse
    let mappedError: any Error
}

/// Preserves overflow identity until retry logic can reject another download of the
/// same oversized response, while retaining the error that public APIs expose.
private nonisolated struct ResponseOverflowFailure: Error {
    let mappedError: any Error
}

private nonisolated struct DecodedAttempt<Value: Sendable>: Sendable {
    let value: Value
    let responseURL: URL
}

/// A lazy page stream. Work begins with the iterator's first `next()` call and is
/// cancelled when that iterator is released, even if the sequence value is retained.
public nonisolated struct PaginatedRESTPageStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias Failure = any Error

    private let produce: @Sendable (@escaping @Sendable (Element) -> Void) async throws -> Void

    nonisolated init(
        produce: @escaping @Sendable (@escaping @Sendable (Element) -> Void) async throws -> Void
    ) {
        self.produce = produce
    }

    public nonisolated func makeAsyncIterator() -> Iterator {
        Iterator(produce: produce)
    }

    public nonisolated final class Iterator: AsyncIteratorProtocol, @unchecked Sendable {
        private let produce: @Sendable (@escaping @Sendable (Element) -> Void) async throws -> Void
        private var iterator: AsyncThrowingStream<Element, any Error>.Iterator?
        private var work: Task<Void, Never>?

        fileprivate init(
            produce: @escaping @Sendable (@escaping @Sendable (Element) -> Void) async throws -> Void
        ) {
            self.produce = produce
        }

        deinit {
            work?.cancel()
        }

        public func next() async throws -> Element? {
            if iterator == nil {
                let (stream, continuation) = AsyncThrowingStream<Element, any Error>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                let produce = produce
                let work = Task {
                    do {
                        try await produce { continuation.yield($0) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in work.cancel() }
                iterator = stream.makeAsyncIterator()
                self.work = work
            }
            return try await iterator?.next()
        }
    }
}

// MARK: - Client

/// The reusable paginator. Carries only immutable, Sendable configuration and drives
/// pure networking through an injected `RESTTransport`, so its stored properties and the
/// low-level request/pagination methods are `nonisolated`: it lets the pagination
/// pipeline run off the main actor (see `streamAllPages`) rather than being pinned to it
/// by the module's default MainActor isolation.
///
/// ## Rate-limit copy semantics
///
/// The client is a value type, but its rate-limit cooldown is stored as a reference.
/// Assigning or passing the client by value therefore shares cooldown state. Independently
/// constructed clients do not share. Call ``withIndependentRateLimits()`` for a copy with
/// a fresh cooldown, or ``sharingRateLimitState(with:)`` when two clients should share
/// intentionally.
public struct PaginatedRESTClient {
    nonisolated let apiKey: String
    nonisolated let baseURL: URL
    /// The networking backend. `URLSessionTransport` by default; inject any `RESTTransport`
    /// to layer the paginator over a different HTTP client (Get, Alamofire) or a test stub.
    nonisolated let transport: any RESTTransport
    /// Builds a configured decoder per call. A factory rather than a shared instance
    /// because decoding runs off the main actor (see `perform`) and `JSONDecoder`
    /// isn't safe to share across threads - each background decode gets its own.
    nonisolated let decoderFactory: @Sendable () -> JSONDecoder
    /// Supplies the encoder for request bodies. A closure (not a stored `JSONEncoder`)
    /// so the paginator stays `Sendable` - its `nonisolated` pagination methods capture
    /// `self` in child tasks, and `JSONEncoder` isn't `Sendable`. The composing client
    /// owns the body shapes and date strategy, so the encoder is a domain concern.
    nonisolated let encoderFactory: @Sendable () -> JSONEncoder
    /// Builds the paginator's failures as the composing client's error type, so this file
    /// names no domain error (see `RESTTransportErrorMapping`).
    nonisolated let errors: any RESTTransportErrorMapping
    /// Where retry diagnostics go. A plain `@Sendable` closure so the package owns no
    /// logging subsystem and stays Foundation-only; defaults to a no-op. Bridge it to
    /// `os.Logger`, `print`, or any sink at the call site.
    ///
    /// The sink must be non-blocking: the client dispatches each message onto a
    /// utility `Task` so a slow sink cannot stall retry delays or concurrent page
    /// fetches. Do not perform synchronous I/O inside the closure.
    nonisolated let log: @Sendable (String) -> Void
    private nonisolated let retryRuntime: RetryRuntime
    private nonisolated let rateLimitCooldown: RateLimitCooldown

    /// Default upper bound on `next_page` follows for one list, guarding against a
    /// server that keeps handing back links. Hitting it throws rather than truncating.
    public nonisolated static let defaultMaxSequentialPages = 1000

    /// Default upper bound on pages the parallel path will request for one list,
    /// mirroring `defaultMaxSequentialPages`. The page count there is derived from a
    /// server-supplied `total`, so without a valve a single bogus `total` turns one
    /// `fetchAllPages` call into thousands of requests. Hitting it throws rather than
    /// truncating.
    public nonisolated static let defaultMaxParallelPages = 1000

    /// Upper bound on `next_page` follows for one list on this client. Counts the
    /// initial page toward the limit.
    nonisolated let maxSequentialPages: Int

    /// Upper bound on pages the parallel path will request for one list on this client.
    nonisolated let maxParallelPages: Int

    /// Retry delays, including server-provided `Retry-After` values, never block the
    /// shared client for longer than one minute.
    public nonisolated static let defaultMaxRetryDelay: TimeInterval = 60

    /// Default number of attempts for idempotent requests, including the first attempt.
    public nonisolated static let defaultMaxAttempts = 3

    /// Upper bound on retry delays, including server-provided `Retry-After` values.
    nonisolated let maxRetryDelay: TimeInterval

    /// Default number of attempts for idempotent requests, including the first attempt.
    nonisolated let maxAttempts: Int

    /// Upper bound on HTTP attempts across one paginated list (retries included) (#123).
    /// Defaults to ``maxSequentialPages`` × ``maxAttempts`` so the page valves cannot be
    /// amplified by the retry budget.
    public nonisolated let maxPaginationHTTPAttempts: Int

    // `nonisolated` so actors and background containers can construct the client
    // without hopping to MainActor; stored state is immutable and Sendable.
    public nonisolated init(
        apiKey: String,
        baseURL: URL,
        transport: any RESTTransport = URLSessionTransport(),
        decoderFactory: @escaping @Sendable () -> JSONDecoder,
        encoderFactory: @escaping @Sendable () -> JSONEncoder,
        errors: any RESTTransportErrorMapping,
        log: @escaping @Sendable (String) -> Void = { _ in },
        maxSequentialPages: Int = Self.defaultMaxSequentialPages,
        maxParallelPages: Int = Self.defaultMaxParallelPages,
        maxRetryDelay: TimeInterval = Self.defaultMaxRetryDelay,
        maxAttempts: Int = Self.defaultMaxAttempts,
        maxPaginationHTTPAttempts: Int? = nil
    ) throws {
        self.init(
            apiKey: apiKey,
            baseURL: try Self.validatedBaseURL(baseURL, errors: errors),
            transport: transport,
            decoderFactory: decoderFactory,
            encoderFactory: encoderFactory,
            errors: errors,
            log: log,
            retryRuntime: .live,
            maxSequentialPages: maxSequentialPages,
            maxParallelPages: maxParallelPages,
            maxRetryDelay: maxRetryDelay,
            maxAttempts: maxAttempts,
            maxPaginationHTTPAttempts: maxPaginationHTTPAttempts
        )
    }

    /// Absolute HTTP(S) origins only: host present, no userinfo.
    nonisolated static func validatedBaseURL(
        _ url: URL,
        errors: any RESTTransportErrorMapping
    ) throws -> URL {
        let stripped = strippingFragment(url)
        guard let components = URLComponents(url: stripped, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil
        else {
            throw errors.invalidRequest("Invalid base URL")
        }
        return stripped
    }

    nonisolated init(
        apiKey: String,
        baseURL: URL,
        transport: any RESTTransport,
        decoderFactory: @escaping @Sendable () -> JSONDecoder,
        encoderFactory: @escaping @Sendable () -> JSONEncoder,
        errors: any RESTTransportErrorMapping,
        log: @escaping @Sendable (String) -> Void = { _ in },
        retryRuntime: RetryRuntime,
        maxSequentialPages: Int = Self.defaultMaxSequentialPages,
        maxParallelPages: Int = Self.defaultMaxParallelPages,
        maxRetryDelay: TimeInterval = Self.defaultMaxRetryDelay,
        maxAttempts: Int = Self.defaultMaxAttempts,
        maxPaginationHTTPAttempts: Int? = nil,
        rateLimitCooldown: RateLimitCooldown = RateLimitCooldown()
    ) {
        self.apiKey = Self.normalizedAPIKey(apiKey) ?? ""
        // Fragments are client-side and must not appear on transport-facing request URLs.
        self.baseURL = Self.strippingFragment(baseURL)
        self.transport = transport
        self.decoderFactory = decoderFactory
        self.encoderFactory = encoderFactory
        self.errors = errors
        self.log = log
        self.retryRuntime = retryRuntime
        self.maxSequentialPages = max(1, maxSequentialPages)
        self.maxParallelPages = max(1, maxParallelPages)
        self.maxRetryDelay = max(0, maxRetryDelay.isFinite ? maxRetryDelay : Self.defaultMaxRetryDelay)
        self.maxAttempts = max(1, maxAttempts)
        let attemptBudget = maxPaginationHTTPAttempts ?? (self.maxSequentialPages * self.maxAttempts)
        self.maxPaginationHTTPAttempts = max(1, attemptBudget)
        self.rateLimitCooldown = rateLimitCooldown
    }

    /// Returns a copy that observes rate limits independently of this instance.
    public nonisolated func withIndependentRateLimits() -> PaginatedRESTClient {
        PaginatedRESTClient(
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport,
            decoderFactory: decoderFactory,
            encoderFactory: encoderFactory,
            errors: errors,
            log: log,
            retryRuntime: retryRuntime,
            maxSequentialPages: maxSequentialPages,
            maxParallelPages: maxParallelPages,
            maxRetryDelay: maxRetryDelay,
            maxAttempts: maxAttempts,
            maxPaginationHTTPAttempts: maxPaginationHTTPAttempts,
            rateLimitCooldown: RateLimitCooldown()
        )
    }

    /// Returns a reconfigured client that shares `other`'s rate-limit cooldown.
    public nonisolated func sharingRateLimitState(with other: PaginatedRESTClient) -> PaginatedRESTClient {
        PaginatedRESTClient(
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport,
            decoderFactory: decoderFactory,
            encoderFactory: encoderFactory,
            errors: errors,
            log: log,
            retryRuntime: retryRuntime,
            maxSequentialPages: maxSequentialPages,
            maxParallelPages: maxParallelPages,
            maxRetryDelay: maxRetryDelay,
            maxAttempts: maxAttempts,
            maxPaginationHTTPAttempts: maxPaginationHTTPAttempts,
            rateLimitCooldown: other.rateLimitCooldown
        )
    }

    public nonisolated func fetch<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        headers: [String: String] = [:]
    ) async throws -> T {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }

        return try await performWithRetry(
            type,
            request: try authorizedGET(try url(forPath: path), headers: headers)
        )
    }

    /// Accumulates every page of a paginated list endpoint. Convenience over
    /// `streamAllPages` for callers that only want the final, complete list.
    public nonisolated func fetchAllPages<W: PagedResponse>(
        _: W.Type,
        path: String,
        sort: String? = nil
    ) async throws -> [W.Item] {
        try await withThrowingTaskGroup(of: [W.Item].self) { group in
            group.addTask {
                try await drivePagination(W.self, path: path, sort: sort) { _ in }
            }
            guard let items = try await group.next() else { throw CancellationError() }
            return items
        }
    }

    /// Streams cumulative snapshots of a paginated list endpoint. The one-element newest
    /// buffer lets callers render before the whole list is in without retaining a quadratic
    /// queue of growing arrays; a slow consumer may skip intermediate cumulative snapshots.
    ///
    /// When the first response reports a `total`, the page count is known up front and the
    /// remaining pages (numbered `?page=2…N`) are fetched concurrently - turning what was a
    /// serial chain of round-trips into a few parallel waves. On a large list this is the
    /// difference between tens of seconds and a few. Completed pages are emitted as a
    /// growing contiguous prefix, so each snapshot is correctly ordered even though pages
    /// finish out of order. Endpoints that omit `total` (or any future cursor-style
    /// pagination) fall back to walking `next_page` sequentially, emitting a snapshot per
    /// page. Without this whole mechanism, callers would silently receive only the first page.
    public nonisolated func streamAllPages<W: PagedResponse>(
        _: W.Type,
        path: String,
        sort: String? = nil
    ) -> PaginatedRESTPageStream<[W.Item]> {
        PaginatedRESTPageStream { emit in
            _ = try await drivePagination(W.self, path: path, sort: sort, emit: emit)
        }
    }

    /// GET requests are idempotent, so transient failures (5xx, 429, network timeouts)
    /// are retried with exponential backoff before the error surfaces to the UI. Mutating
    /// requests go straight through `perform` to avoid duplicating side effects.
    /// File-backed bodies are not auto-retried: each attempt would reopen the file and
    /// could send different bytes if the file changed between attempts.
    public nonisolated func performWithRetry<T: Decodable & Sendable>(
        _ type: T.Type,
        request: RESTRequest,
        maxAttempts: Int? = nil
    ) async throws -> T {
        try await performWithRetryAttempt(type, request: request, maxAttempts: maxAttempts).value
    }

    private nonisolated func performWithRetryAttempt<T: Decodable & Sendable>(
        _ type: T.Type,
        request: RESTRequest,
        maxAttempts: Int? = nil,
        attemptBudget: PaginationHTTPAttemptBudget? = nil
    ) async throws -> DecodedAttempt<T> {
        let attempts = maxAttempts ?? self.maxAttempts
        guard attempts > 0 else { throw errors.decode("maxAttempts must be positive") }
        let retryAttempts = Self.methodIsIdempotent(request.method) && request.bodyFileURL == nil ? attempts : 1

        var attempt = 0
        while true {
            do {
                try attemptBudget?.consume()
                return try await performAttempt(type, request: request)
            } catch let failure as HTTPAttemptFailure {
                attempt += 1

                if failure.response.statusCode == 429 {
                    guard attempt < retryAttempts, errors.isTransient(failure.mappedError) else {
                        observeRateLimitCooldown(from: failure.response, request: request)
                        try Task.checkCancellation()
                        throw failure.mappedError
                    }
                    let now = retryRuntime.now()
                    let retryAfter = Self.retryAfterDelay(from: failure.response, receivedAt: now)
                    let delay = min(maxRetryDelay, retryAfter ?? Self.rateLimitFallbackDelay(
                        retryNumber: attempt,
                        jitter: retryRuntime.jitter()
                    ))
                    extendRateLimitCooldown(by: delay, request: request)
                    emitLog(
                        "Rate limited; retry \(attempt)/\(retryAttempts - 1) "
                            + "after shared \(String(format: "%.3f", delay))s cooldown"
                    )
                    try await waitForRateLimitCooldown(for: request)
                    continue
                }

                guard attempt < retryAttempts, errors.isTransient(failure.mappedError) else {
                    try Task.checkCancellation()
                    throw failure.mappedError
                }

                if Self.honorsRetryAfter(statusCode: failure.response.statusCode),
                   let retryAfter = Self.retryAfterDelay(
                       from: failure.response,
                       receivedAt: retryRuntime.now()
                   ) {
                    let delay = min(maxRetryDelay, retryAfter)
                    emitLog(
                        "Transient failure; retry \(attempt)/\(retryAttempts - 1) "
                            + "after \(String(format: "%.3f", delay))s Retry-After"
                    )
                    try await retryRuntime.sleep(delay)
                    continue
                }

                emitLog("Transient failure; retry \(attempt)/\(retryAttempts - 1)")
                try await retryRuntime.sleep(retryBackoffDelay(retryNumber: attempt))
            } catch is CancellationError {
                throw CancellationError()
            } catch let overflow as ResponseOverflowFailure {
                throw overflow.mappedError
            } catch let bodyError as RESTRequestBodyError {
                throw mappedBodyError(bodyError)
            } catch let requestError as RESTRequestError {
                throw mappedRequestError(requestError)
            } catch {
                attempt += 1
                guard attempt < retryAttempts, errors.isTransient(error) else {
                    try Task.checkCancellation()
                    throw error
                }

                emitLog("Transient failure; retry \(attempt)/\(retryAttempts - 1)")
                // Preserve the existing 300ms, then 600ms exponential policy for
                // non-HTTP transient errors. The injected sleep remains cancellable.
                try await retryRuntime.sleep(retryBackoffDelay(retryNumber: attempt))
            }
        }
    }

    public nonisolated func send<T: Decodable & Sendable>(
        _ type: T.Type,
        method: String,
        path: String,
        body: some Encodable & Sendable
    ) async throws -> T {
        try await perform(type, request: try await makeSendRequest(method: method, path: path, body: body))
    }

    /// Sends a JSON body when the response has no model (for example HTTP 204/205).
    public nonisolated func send(
        method: String,
        path: String,
        body: some Encodable & Sendable
    ) async throws {
        try await performNoContentWithRetry(
            request: try await makeSendRequest(method: method, path: path, body: body)
        )
    }

    /// Sends an authenticated request without a body.
    public nonisolated func send<T: Decodable & Sendable>(
        _ type: T.Type,
        method: String,
        path: String
    ) async throws -> T {
        try await perform(type, request: try authorizedRequest(method: method, path: path))
    }

    /// Sends an authenticated request without a body when the response has no model.
    public nonisolated func send(method: String, path: String) async throws {
        try await performNoContentWithRetry(
            request: try authorizedRequest(method: method, path: path)
        )
    }

    /// Sends an authenticated request whose body is streamed from a local file.
    public nonisolated func send<T: Decodable & Sendable>(
        _ type: T.Type,
        method: String,
        path: String,
        bodyFileURL: URL
    ) async throws -> T {
        try await perform(
            type,
            request: try authorizedRequest(method: method, path: path, bodyFileURL: bodyFileURL)
        )
    }

    /// Sends an authenticated file-backed request when the response has no model.
    public nonisolated func send(
        method: String,
        path: String,
        bodyFileURL: URL
    ) async throws {
        try await performNoContentWithRetry(
            request: try authorizedRequest(method: method, path: path, bodyFileURL: bodyFileURL)
        )
    }

    public nonisolated func perform<T: Decodable & Sendable>(
        _ type: T.Type,
        request: RESTRequest
    ) async throws -> T {
        do {
            return try await performAttempt(type, request: request).value
        } catch let failure as HTTPAttemptFailure {
            observeRateLimitCooldown(from: failure.response, request: request)
            try Task.checkCancellation()
            throw failure.mappedError
        } catch let bodyError as RESTRequestBodyError {
            throw mappedBodyError(bodyError)
        } catch let requestError as RESTRequestError {
            throw mappedRequestError(requestError)
        } catch let overflow as ResponseOverflowFailure {
            throw overflow.mappedError
        }
    }

    private nonisolated func performAttempt<T: Decodable & Sendable>(
        _ type: T.Type,
        request: RESTRequest
    ) async throws -> DecodedAttempt<T> {
        let response: RESTResponse
        do {
            response = try await transportResponse(for: request)
        } catch let overflow as RESTResponseTooLargeError {
            throw ResponseOverflowFailure(mappedError: mappedOverflow(overflow))
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw HTTPAttemptFailure(
                response: response,
                mappedError: errors.http(
                    status: response.statusCode,
                    body: Self.boundedErrorBody(response.data)
                )
            )
        }

        do {
            // Decode off the main actor: the client may be MainActor-isolated, so on a large
            // list (many pages × nested objects) decoding here would hitch the UI.
            // `Data` and `T` are Sendable, so the work crosses the boundary cleanly.
            let value = try await decodeInBackground(T.self, from: response.data)
            return DecodedAttempt(value: value, responseURL: response.url ?? request.url)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw errors.decode("missing key '\(key.stringValue)' at \(pathString(ctx.codingPath))")
        } catch let DecodingError.valueNotFound(type, ctx) {
            throw errors.decode("missing value of \(type) at \(pathString(ctx.codingPath))")
        } catch let DecodingError.typeMismatch(type, ctx) {
            throw errors.decode(
                "type mismatch (\(type)) at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
            )
        } catch let DecodingError.dataCorrupted(ctx) {
            throw errors.decode("corrupted at \(pathString(ctx.codingPath)): \(ctx.debugDescription)")
        } catch is CancellationError { throw CancellationError() } catch {
            throw errors.decode(Self.boundedDecodeDetail(error))
        }
    }

    private nonisolated func transportResponse(
        for request: RESTRequest,
        discardingSuccessBody: Bool = false
    ) async throws -> RESTResponse {
        try request.validate()
        try await waitForRateLimitCooldown(for: request)
        try Task.checkCancellation()

        do {
            if discardingSuccessBody {
                return try await transport.responseDiscardingSuccessBody(for: request)
            }
            return try await transport.response(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            try Task.checkCancellation()
            // Surface transport failures (offline, timeout, unreachable) as a typed,
            // friendly error rather than leaking the raw URLError into the UI.
            throw errors.network(urlError)
        }
    }

    /// Maps a body-size overflow while preserving HTTP classification for non-2xx
    /// responses so a huge 401/404/429/500 is not reported as a decode failure.
    private nonisolated func mappedOverflow(_ overflow: RESTResponseTooLargeError) -> any Error {
        var detail = "HTTP \(overflow.statusCode) response exceeded the \(overflow.limit)-byte limit"
        detail += " during \(overflow.phase.rawValue)"
        if let declared = overflow.declaredContentLength {
            detail += " (declared \(declared) bytes"
            detail += ", observed \(overflow.observedByteCount) bytes)"
        } else {
            detail += " (observed \(overflow.observedByteCount) bytes)"
        }
        if (200 ..< 300).contains(overflow.statusCode) {
            return errors.decode(detail)
        }
        return errors.http(status: overflow.statusCode, body: detail)
    }

    /// Dispatches diagnostics off the calling task so a slow sink cannot block retries.
    private nonisolated func emitLog(_ message: String) {
        let sink = log
        Task(priority: .utility) {
            sink(message)
        }
    }

    /// Publishes an observed 429 into the shared cooldown without deciding whether to retry.
    private nonisolated func observeRateLimitCooldown(
        from response: RESTResponse,
        request: RESTRequest
    ) {
        guard response.statusCode == 429 else { return }
        let now = retryRuntime.now()
        let retryAfter = Self.retryAfterDelay(from: response, receivedAt: now)
        let delay = min(
            maxRetryDelay,
            retryAfter ?? Self.rateLimitFallbackDelay(retryNumber: 1, jitter: retryRuntime.jitter())
        )
        extendRateLimitCooldown(by: delay, request: request)
    }

    private nonisolated func extendRateLimitCooldown(
        by delay: TimeInterval,
        request: RESTRequest
    ) {
        let now = retryRuntime.monotonicNow()
        rateLimitCooldown.extend(
            until: now + delay,
            observedAt: now,
            maximumWindow: maxRetryDelay,
            for: Self.rateLimitOriginKey(request.url)
        )
    }

    private nonisolated func mappedBodyError(_ error: RESTRequestBodyError) -> any Error {
        errors.invalidRequest(Self.describeBodyError(error))
    }

    private nonisolated func mappedRequestError(_ error: RESTRequestError) -> any Error {
        switch error {
        case let .invalidHTTPMethod(method):
            errors.invalidRequest("Invalid HTTP method \(method)")
        case let .unsupportedURL(url):
            errors.invalidRequest("Unsupported URL \(url.absoluteString)")
        case .invalidHeaderField:
            errors.invalidRequest("Request contains an invalid HTTP header field")
        case let .duplicateHeaderField(name):
            errors.invalidRequest("Request contains duplicate HTTP header field \(name)")
        case .unsupportedBackgroundSession:
            errors.invalidRequest("Background URLSession configurations are not supported")
        }
    }

    private nonisolated func makeSendRequest<Body: Encodable & Sendable>(
        method: String,
        path: String,
        body: Body
    ) async throws -> RESTRequest {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }
        guard Self.methodAllowsJSONBody(method) else {
            throw errors.invalidRequest(
                "send requires a method that allows a JSON body; use fetch for GET/HEAD"
            )
        }
        let encoded: Data
        do {
            // Detach from the caller executor so large JSON bodies do not encode on
            // MainActor (or any other caller actor) under NonisolatedNonsendingByDefault.
            let makeEncoder = encoderFactory
            encoded = try await Task.detached {
                try Task.checkCancellation()
                return try makeEncoder().encode(body)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw errors.encode(Self.boundedEncodeDetail(error))
        }
        return try authorizedRequest(
            method: method,
            path: path,
            headers: ["Content-Type": "application/json"],
            body: encoded
        )
    }

    /// Waits against the latest shared deadline. The loop matters when a sibling receives
    /// a later `Retry-After` while this task is already sleeping.
    private nonisolated func waitForRateLimitCooldown(for request: RESTRequest) async throws {
        let key = Self.rateLimitOriginKey(request.url)
        while let delay = rateLimitCooldown.remaining(at: retryRuntime.monotonicNow(), for: key) {
            try Task.checkCancellation()
            try await retryRuntime.sleep(delay)
        }
    }

    private nonisolated func pathString(_ keys: [CodingKey]) -> String {
        keys.isEmpty ? "$" : keys.map(\.stringValue).joined(separator: ".")
    }

    /// Decodes `data` on a background task so the (potentially large) parse doesn't run on
    /// the main actor. Builds a fresh decoder per call - `JSONDecoder` isn't safe to share
    /// across threads. `DecodingError`s propagate so `perform` can map them as before.
    ///
    /// A structured child task inherits cancellation, so a stream teardown cancels queued
    /// decode work instead of letting it parse a result that will be discarded.
    private nonisolated func decodeInBackground<T: Decodable & Sendable>(
        _: T.Type,
        from data: Data
    ) async throws -> T {
        let make = decoderFactory
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try Task.checkCancellation()
                return try make().decode(T.self, from: data)
            }
            guard let decoded = try await group.next() else {
                throw CancellationError()
            }
            return decoded
        }
    }
}

extension PaginatedRESTClient {
    private nonisolated struct HTTPDateToken {
        let day: Int
        let month: Int
        let year: Int
    }

    private nonisolated struct HTTPTime {
        let hour: Int
        let minute: Int
        let second: Int
    }

    /// Parses RFC delay-seconds and the three HTTP-date productions. Dates must use the
    /// exact HTTP-date grammar (including GMT); malformed and negative values fall back.
    /// RFC850 two-digit years follow the HTTP >50-years-in-the-future rule.
    nonisolated static func retryAfterDelay(_ value: String?, relativeTo now: Date) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII),
           trimmed.allSatisfy(\.isNumber), let seconds = TimeInterval(trimmed), seconds.isFinite {
            return seconds
        }
        guard let date = parseHTTPDate(trimmed, relativeTo: now) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Absolute retry dates are server-relative when a valid response `Date` is present.
    /// Delta-seconds remain relative to receipt time as required by HTTP.
    nonisolated static func retryAfterDelay(
        from response: RESTResponse,
        receivedAt now: Date
    ) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII),
           trimmed.allSatisfy(\.isNumber), let seconds = TimeInterval(trimmed), seconds.isFinite {
            return seconds
        }
        let reference = response.value(forHTTPHeaderField: "Date")
            .flatMap { parseHTTPDate($0, relativeTo: now) } ?? now
        guard let date = parseHTTPDate(trimmed, relativeTo: reference) else { return nil }
        return max(0, date.timeIntervalSince(reference))
    }

    /// IMF-fixdate, RFC850, and asctime forms from RFC 9110.
    nonisolated static func parseHTTPDate(_ value: String, relativeTo now: Date) -> Date? {
        if let date = parseIMFFixDate(value) { return date }
        if let date = parseRFC850Date(value, relativeTo: now) { return date }
        return parseAsctimeDate(value)
    }

    private nonisolated static var httpMonths: [String: Int] {
        [
            "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
            "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12
        ]
    }

    private nonisolated static var httpWeekdays: Set<String> {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }

    private nonisolated static var httpWeekdaysLong: Set<String> {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    }

    private nonisolated static func parseIMFFixDate(_ value: String) -> Date? {
        // Sun, 06 Nov 1994 08:49:37 GMT
        let parts = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6,
              parts[0].hasSuffix(","),
              httpWeekdays.contains(String(parts[0].dropLast())),
              parts[1].count == 2, let day = Int(parts[1]), (1 ... 31).contains(day),
              let month = httpMonths[parts[2]],
              parts[3].count == 4, let year = Int(parts[3]), year >= 1601,
              let time = parseHTTPTime(parts[4]),
              parts[5] == "GMT"
        else { return nil }
        return makeGMTDate(
            year: year, month: month, day: day,
            hour: time.hour, minute: time.minute, second: time.second
        ).flatMap { date in
            matchesWeekday(parts[0].dropLast(), date: date) ? date : nil
        }
    }

    private nonisolated static func parseRFC850Date(_ value: String, relativeTo now: Date) -> Date? {
        // Sunday, 06-Nov-94 08:49:37 GMT
        let parts = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              parts[0].hasSuffix(","),
              httpWeekdaysLong.contains(String(parts[0].dropLast())),
              let dateParts = parseRFC850DateToken(parts[1]),
              let time = parseHTTPTime(parts[2]),
              parts[3] == "GMT"
        else { return nil }
        let year = interpretTwoDigitYear(dateParts.year, relativeTo: now)
        return makeGMTDate(
            year: year, month: dateParts.month, day: dateParts.day,
            hour: time.hour, minute: time.minute, second: time.second
        ).flatMap { date in
            matchesWeekdayLong(parts[0].dropLast(), date: date) ? date : nil
        }
    }

    private nonisolated static func parseAsctimeDate(_ value: String) -> Date? {
        // Sun Nov  6 08:49:37 1994
        let parts = value.split(whereSeparator: { $0 == " " }).map(String.init)
        guard parts.count == 5,
              httpWeekdays.contains(parts[0]),
              let month = httpMonths[parts[1]],
              let day = Int(parts[2]), (1 ... 31).contains(day),
              let time = parseHTTPTime(parts[3]),
              parts[4].count == 4, let year = Int(parts[4]), year >= 1601
        else { return nil }
        return makeGMTDate(
            year: year, month: month, day: day,
            hour: time.hour, minute: time.minute, second: time.second
        ).flatMap { date in
            matchesWeekday(Substring(parts[0]), date: date) ? date : nil
        }
    }

    private nonisolated static func parseRFC850DateToken(
        _ token: String
    ) -> HTTPDateToken? {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0].count == 2, let day = Int(parts[0]), (1 ... 31).contains(day),
              let month = httpMonths[parts[1]],
              parts[2].count == 2, let year = Int(parts[2]), (0 ... 99).contains(year)
        else { return nil }
        return HTTPDateToken(day: day, month: month, year: year)
    }

    private nonisolated static func parseHTTPTime(_ value: String) -> HTTPTime? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0].count == 2, let hour = Int(parts[0]), (0 ... 23).contains(hour),
              parts[1].count == 2, let minute = Int(parts[1]), (0 ... 59).contains(minute),
              parts[2].count == 2, let second = Int(parts[2]), (0 ... 60).contains(second)
        else { return nil }
        return HTTPTime(hour: hour, minute: minute, second: second)
    }

    /// HTTP rfc850-date: a year more than 50 years ahead becomes the most recent past match.
    nonisolated static func interpretTwoDigitYear(_ year: Int, relativeTo now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentYear = calendar.component(.year, from: now)
        var fullYear = (currentYear / 100) * 100 + year
        if fullYear > currentYear + 50 {
            fullYear -= 100
        }
        return fullYear
    }

    private nonisolated static func makeGMTDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else { return nil }
        let echoed = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard echoed.year == year, echoed.month == month, echoed.day == day,
              echoed.hour == hour, echoed.minute == minute, echoed.second == second
        else { return nil }
        return date
    }

    private nonisolated static func matchesWeekday(_ token: Substring, date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekday = calendar.component(.weekday, from: date)
        guard (1 ... 7).contains(weekday) else { return false }
        return symbols[weekday - 1] == token
    }

    private nonisolated static func matchesWeekdayLong(_ token: Substring, date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let symbols = [
            "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
        ]
        let weekday = calendar.component(.weekday, from: date)
        guard (1 ... 7).contains(weekday) else { return false }
        return symbols[weekday - 1] == token
    }

    /// Positive jitter above a conservative one-second exponential base, capped at
    /// one minute. `jitter` is clamped so a custom random source cannot violate the cap.
    nonisolated static func rateLimitFallbackDelay(retryNumber: Int, jitter: Double) -> TimeInterval {
        let exponent = Double(min(max(retryNumber - 1, 0), 10))
        let base = min(60, pow(2, exponent))
        let factor = 1 + (0.25 * min(max(jitter, 0), 1))
        return min(60, base * factor)
    }

    nonisolated static var maxMappedErrorBodyBytes: Int { 4 * 1_024 }
    nonisolated static var maxMappedErrorBodyScalars: Int { 1_024 }

    nonisolated static func boundedErrorBody(_ data: Data) -> String {
        let end = utf8PrefixEndIndex(data, maxBytes: maxMappedErrorBodyBytes)
        let prefix = data.prefix(end)
        // Lossy decoding is deliberate for remaining invalid bytes: they become a
        // bounded replacement scalar instead of making the mapped error body disappear.
        // swiftlint:disable:next optional_data_string_conversion
        let decoded = String(decoding: [UInt8](prefix), as: UTF8.self)
        return sanitizedText(
            decoded,
            maxScalars: maxMappedErrorBodyScalars,
            truncated: data.count > end
        )
    }

    /// Largest prefix of `data` that is at most `maxBytes` and does not end mid-scalar.
    nonisolated static func utf8PrefixEndIndex(_ data: Data, maxBytes: Int) -> Int {
        guard maxBytes > 0, !data.isEmpty else { return 0 }
        if data.count <= maxBytes { return data.count }
        let bytes = [UInt8](data)
        var end = maxBytes
        // Back up over trailing continuation bytes so `end` is at a potential lead/ASCII.
        while end > 0 && (bytes[end - 1] & 0xC0) == 0x80 {
            end -= 1
        }
        guard end > 0 else { return 0 }
        let lead = bytes[end - 1]
        let needed: Int
        switch lead {
        case 0x00 ..< 0x80: needed = 1
        case 0xC0 ..< 0xE0: needed = 2
        case 0xE0 ..< 0xF0: needed = 3
        case 0xF0 ..< 0xF8: needed = 4
        default: needed = 1
        }
        // Incomplete sequence at the cut: drop the lead. Otherwise advance past the
        // complete scalar that starts at `end - 1` (which may still fit in `maxBytes`).
        if end - 1 + needed > maxBytes {
            end -= 1
        } else {
            end = end - 1 + needed
        }
        return end
    }

    nonisolated static func boundedDecodeDetail(_ error: any Error) -> String {
        sanitizedText(
            "decode failed (\(type(of: error))): \(error.localizedDescription)",
            maxScalars: 512,
            truncated: false
        )
    }

    nonisolated static func boundedEncodeDetail(_ error: any Error) -> String {
        sanitizedText(
            "encode failed (\(type(of: error))): \(error.localizedDescription)",
            maxScalars: 512,
            truncated: false
        )
    }

    nonisolated static func describeBodyError(_ error: RESTRequestBodyError) -> String {
        switch error {
        case .multipleSources:
            "Request supplied both an in-memory body and a body file"
        case let .bodyFileMustBeFileURL(url):
            "Request body file must be a file URL (\(url.absoluteString))"
        case let .unreadableBodyFile(url):
            "Request body file is unreadable (\(url.absoluteString))"
        case let .contentLengthMismatch(expected, declared):
            "Request Content-Length \(declared) does not match body file size \(expected)"
        }
    }

    private nonisolated static func sanitizedText(
        _ text: String,
        maxScalars: Int,
        truncated: Bool
    ) -> String {
        var result = String.UnicodeScalarView()
        var scalarTruncated = false
        for scalar in text.unicodeScalars {
            guard result.count < maxScalars else { scalarTruncated = true; break }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned:
                result.append("�")
            default:
                result.append(scalar)
            }
        }
        var string = String(result)
        if truncated || scalarTruncated { string += " [truncated]" }
        return string
    }

    nonisolated static func retryBackoffDelay(retryNumber: Int) -> TimeInterval {
        let exponent = Double(min(max(retryNumber - 1, 0), 10))
        return min(defaultMaxRetryDelay, 0.3 * pow(2, exponent))
    }

    nonisolated static func methodIsIdempotent(_ method: String) -> Bool {
        // HTTP method tokens are case-sensitive; only the standard uppercase forms
        // are treated as idempotent. Do not mutate or normalize the request method.
        ["GET", "HEAD", "OPTIONS", "TRACE", "PUT", "DELETE"].contains(method)
    }

    /// Statuses for which HTTP defines or commonly advertises `Retry-After`.
    nonisolated static func honorsRetryAfter(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 503 || statusCode == 413
    }

    /// GET and HEAD must not carry a JSON body; callers should use ``fetch`` instead.
    nonisolated static func methodAllowsJSONBody(_ method: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD": false
        default: true
        }
    }

    nonisolated static func rateLimitOriginKey(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else { return url.absoluteString }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(components.port ?? defaultPort)"
    }

    private nonisolated func retryBackoffDelay(retryNumber: Int) -> TimeInterval {
        let exponent = Double(min(max(retryNumber - 1, 0), 10))
        let base = 0.3 * pow(2, exponent)
        let factor = 1 + (0.25 * min(max(retryRuntime.jitter(), 0), 1))
        return min(maxRetryDelay, base * factor)
    }
}

public extension PaginatedRESTClient {
    /// Builds an authenticated request for a path on the configured origin. Callers can
    /// supply raw or file-backed bodies without exposing the bearer credential to another
    /// origin. The generated authorization header always replaces a caller-supplied one.
    /// Builds an authenticated request for the configured origin. Validates origin/userinfo
    /// and body-source exclusivity before returning a transport-ready ``RESTRequest``.
    nonisolated func authorizedRequest(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        bodyFileURL: URL? = nil
    ) throws -> RESTRequest {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }
        let url = try validatedAuthenticatedURL(try url(forPath: path))
        var authenticatedHeaders = headers.filter {
            $0.key.compare("Authorization", options: .caseInsensitive) != .orderedSame
        }
        if !authenticatedHeaders.keys.contains(where: {
            $0.compare("Accept", options: .caseInsensitive) == .orderedSame
        }) {
            authenticatedHeaders["Accept"] = "application/json"
        }
        authenticatedHeaders["Authorization"] = "Bearer \(apiKey)"
        let request = RESTRequest(
            url: url,
            method: method,
            headers: authenticatedHeaders,
            body: body,
            bodyFileURL: bodyFileURL
        )
        try request.validate()
        return request
    }

    /// Builds an authenticated GET only for the configured origin. This method throws
    /// rather than placing bearer credentials on an arbitrary caller-provided URL.
    nonisolated func authorizedGET(_ url: URL, headers: [String: String] = [:]) throws -> RESTRequest {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }
        let validated = try validatedAuthenticatedURL(url)
        var authenticatedHeaders = headers.filter {
            $0.key.compare("Authorization", options: .caseInsensitive) != .orderedSame
        }
        if !authenticatedHeaders.keys.contains(where: {
            $0.compare("Accept", options: .caseInsensitive) == .orderedSame
        }) {
            authenticatedHeaders["Accept"] = "application/json"
        }
        authenticatedHeaders["Authorization"] = "Bearer \(apiKey)"
        let request = RESTRequest(
            url: validated,
            method: "GET",
            headers: authenticatedHeaders
        )
        try request.validate()
        return request
    }

    /// Validates that `url` stays on the configured HTTP(S) origin without URL userinfo,
    /// matching the credential-safety rules used by ``fetch(_:path:)``.
    nonisolated func validatedAuthenticatedURL(_ url: URL) throws -> URL {
        guard SameOriginRedirectDelegate.hasSameOrigin(baseURL, url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil
        else {
            throw errors.invalidRequest("Authenticated URL left the configured origin")
        }
        return url
    }

    /// Resolves the public `path` argument as a path reference, preserving the configured
    /// base URL unchanged for an empty reference and merging a supplied query separately.
    /// `URL.appending(path:)` cannot do this because it percent-encodes `?` as path data.
    nonisolated func url(forPath path: String) throws -> URL {
        guard !path.isEmpty else { return baseURL }
        guard let reference = URLComponents(string: path),
              reference.scheme == nil,
              reference.host == nil,
              reference.user == nil,
              reference.password == nil
        else {
            throw errors.invalidRequest("Path must be a relative path reference")
        }
        let appended = baseURL.appending(path: reference.path)
        guard var components = URLComponents(url: appended, resolvingAgainstBaseURL: false) else {
            throw errors.invalidRequest("Invalid URL")
        }
        let baseQuery = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery
        components.percentEncodedQuery = Self.joinedPercentEncodedQueries(
            baseQuery,
            reference.percentEncodedQuery
        )
        // A fragment is never sent over HTTP and must not silently alter URL construction.
        components.fragment = nil
        guard let url = components.url else { throw errors.invalidRequest("Invalid URL") }
        return url
    }

    /// Executes a request that has no response model. Any 2xx response succeeds,
    /// whether its body is empty (including 204) or contains optional server metadata.
    nonisolated func performNoContent(request: RESTRequest) async throws {
        do {
            let response: RESTResponse
            do {
                response = try await transportResponse(for: request, discardingSuccessBody: true)
            } catch let overflow as RESTResponseTooLargeError {
                throw ResponseOverflowFailure(mappedError: mappedOverflow(overflow))
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                throw HTTPAttemptFailure(
                    response: response,
                    mappedError: errors.http(
                        status: response.statusCode,
                        body: Self.boundedErrorBody(response.data)
                    )
                )
            }
        } catch let failure as HTTPAttemptFailure {
            observeRateLimitCooldown(from: failure.response, request: request)
            try Task.checkCancellation()
            throw failure.mappedError
        } catch let bodyError as RESTRequestBodyError {
            throw mappedBodyError(bodyError)
        } catch let requestError as RESTRequestError {
            throw mappedRequestError(requestError)
        } catch let overflow as ResponseOverflowFailure {
            throw overflow.mappedError
        }
    }

    /// Retries an idempotent no-content request using the same policy as
    /// ``performWithRetry(_:request:maxAttempts:)``.
    nonisolated func performNoContentWithRetry(
        request: RESTRequest,
        maxAttempts: Int? = nil
    ) async throws {
        let attempts = maxAttempts ?? self.maxAttempts
        guard attempts > 0 else { throw errors.decode("maxAttempts must be positive") }
        guard Self.methodIsIdempotent(request.method) else {
            try await performNoContent(request: request)
            return
        }

        let retryAttempts = request.bodyFileURL == nil ? attempts : 1
        var attempt = 0
        while true {
            do {
                let response: RESTResponse
                do {
                    response = try await transportResponse(for: request, discardingSuccessBody: true)
                } catch let overflow as RESTResponseTooLargeError {
                    throw ResponseOverflowFailure(mappedError: mappedOverflow(overflow))
                }
                guard (200 ..< 300).contains(response.statusCode) else {
                    throw HTTPAttemptFailure(
                        response: response,
                        mappedError: errors.http(
                            status: response.statusCode,
                            body: Self.boundedErrorBody(response.data)
                        )
                    )
                }
                return
            } catch let failure as HTTPAttemptFailure {
                attempt += 1
                guard attempt < retryAttempts, errors.isTransient(failure.mappedError) else {
                    if failure.response.statusCode == 429 {
                        observeRateLimitCooldown(from: failure.response, request: request)
                    }
                    throw failure.mappedError
                }
                if failure.response.statusCode == 429 {
                    let now = retryRuntime.now()
                    let delay = min(
                        maxRetryDelay,
                        Self.retryAfterDelay(from: failure.response, receivedAt: now)
                            ?? Self.rateLimitFallbackDelay(
                                retryNumber: attempt,
                                jitter: retryRuntime.jitter()
                            )
                    )
                    extendRateLimitCooldown(by: delay, request: request)
                    try await waitForRateLimitCooldown(for: request)
                } else if Self.honorsRetryAfter(statusCode: failure.response.statusCode),
                          let delay = Self.retryAfterDelay(
                              from: failure.response,
                              receivedAt: retryRuntime.now()
                          ) {
                    try await retryRuntime.sleep(min(maxRetryDelay, delay))
                } else {
                    try await retryRuntime.sleep(retryBackoffDelay(retryNumber: attempt))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let overflow as ResponseOverflowFailure {
                throw overflow.mappedError
            } catch let bodyError as RESTRequestBodyError {
                throw mappedBodyError(bodyError)
            } catch let requestError as RESTRequestError {
                throw mappedRequestError(requestError)
            } catch {
                attempt += 1
                guard attempt < retryAttempts, errors.isTransient(error) else {
                    try Task.checkCancellation()
                    throw error
                }
                try await retryRuntime.sleep(retryBackoffDelay(retryNumber: attempt))
            }
        }
    }
}

extension PaginatedRESTClient {
    nonisolated static func normalizedAPIKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.allSatisfy({ (0x21 ... 0x7E).contains($0) })
        else { return nil }
        return trimmed
    }

    /// URL fragments never reach an HTTP server; strip them so every `RESTRequest`
    /// (and every custom transport) observes the same request target.
    nonisolated static func strippingFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    /// `ceil(total / pageSize)` without the overflow-prone `total + pageSize - 1` form.
    nonisolated static func pageCount(total: Int, pageSize: Int) -> Int {
        if total <= 0 { return 1 }
        if pageSize >= total { return 1 }
        let quotient = total / pageSize
        let remainder = total % pageSize
        return quotient + (remainder == 0 ? 0 : 1)
    }

    /// True when `value` is a signed decimal integer literal (digits with an optional
    /// leading `-`). Used to distinguish cursor tokens from malformed/overflowing
    /// numeric `page` query values.
    nonisolated static func isDecimalIntegerLiteral(_ value: String) -> Bool {
        let digits: Substring
        if value.first == "-" {
            digits = value.dropFirst()
        } else {
            digits = Substring(value)
        }
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    nonisolated static func joinedPercentEncodedQueries(_ first: String?, _ second: String?) -> String? {
        let joined = [first, second].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: "&")
        return joined.isEmpty ? nil : joined
    }

    /// Replaces exact-name query fields without decoding and reserializing unrelated bytes.
    nonisolated static func replacingPercentEncodedQueryFields(
        in url: URL,
        replacements: [(name: String, value: String?)]
    ) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let names = Set(replacements.map(\.name))
        var fields = (components.percentEncodedQuery ?? "").split(
            separator: "&",
            omittingEmptySubsequences: false
        ).map(String.init)
        fields.removeAll { field in
            let encodedName = String(field.split(separator: "=", maxSplits: 1).first ?? "")
            return encodedName.removingPercentEncoding.map(names.contains) ?? false
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        for replacement in replacements {
            guard let value = replacement.value,
                  let encodedName = replacement.name.addingPercentEncoding(withAllowedCharacters: allowed),
                  let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)
            else { continue }
            fields.append("\(encodedName)=\(encodedValue)")
        }
        let query = fields.filter { !$0.isEmpty }.joined(separator: "&")
        components.percentEncodedQuery = query.isEmpty ? nil : query
        return components.url
    }

    /// Uses response-provided fields as an overlay while retaining base fields the
    /// response link did not mention.
    nonisolated static func overlayingPercentEncodedQuery(from overlay: URL, onto base: URL) -> URL? {
        guard var components = URLComponents(url: overlay, resolvingAgainstBaseURL: false),
              let overlayComponents = URLComponents(url: overlay, resolvingAgainstBaseURL: false),
              let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        let overlayFields = (overlayComponents.percentEncodedQuery ?? "").split(
            separator: "&",
            omittingEmptySubsequences: false
        ).map(String.init).filter { !$0.isEmpty }
        let overlayNames = Set(overlayFields.compactMap { field in
            String(field.split(separator: "=", maxSplits: 1).first ?? "").removingPercentEncoding
        })
        let baseFields = (baseComponents.percentEncodedQuery ?? "").split(
            separator: "&",
            omittingEmptySubsequences: false
        ).map(String.init).filter { field in
            guard !field.isEmpty else { return false }
            let name = String(field.split(separator: "=", maxSplits: 1).first ?? "")
                .removingPercentEncoding
            return name.map { !overlayNames.contains($0) } ?? true
        }
        let query = (baseFields + overlayFields).joined(separator: "&")
        components.percentEncodedQuery = query.isEmpty ? nil : query
        return components.url
    }

    nonisolated static func uniqueNumericPageValue(_ url: URL) -> Int? {
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == "page" }
            .compactMap(\.value) ?? []
        guard values.count == 1, isDecimalIntegerLiteral(values[0]) else { return nil }
        return Int(values[0])
    }
}

// MARK: - Pagination pipeline

/// The multi-page machinery: path selection, ordered stitching, and the two page-walking
/// strategies. Split into its own extension so the type above stays the client surface
/// (configuration, single requests, retry) and this stays the pagination algorithm.
extension PaginatedRESTClient {
/// Drives the page-by-page fetch, calling `emit` with each cumulative snapshot.
/// Splits into the parallel "fast path" (when `total` is known) and the
/// sequential `next_page` walk, both extracted into helpers below.
nonisolated func drivePagination<W: PagedResponse>(
    _: W.Type,
    path: String,
    sort: String?,
    emit: @Sendable ([W.Item]) -> Void
) async throws -> [W.Item] {
    guard !apiKey.isEmpty else { throw errors.missingAPIKey() }

    /// Builds `…/path?sort=…&page=N`. Page numbers are constructed here
    /// rather than taken from `next_page` so the parallel fetch is
    /// fully deterministic. Any pre-existing `page` query is replaced (or
    /// removed for the first request) so parallel numbering always treats the
    /// first response as page 1.
    func pageURL(_ page: Int?) -> URL? {
        guard let endpoint = try? url(forPath: path) else { return nil }
        return Self.replacingPercentEncodedQueryFields(
            in: endpoint,
            replacements: [
                (name: "sort", value: sort),
                (name: "page", value: page.map(String.init))
            ]
        )
    }

    guard let firstURL = pageURL(nil) else { throw errors.invalidRequest("Invalid URL") }

    let attemptBudget = PaginationHTTPAttemptBudget(
        limit: maxPaginationHTTPAttempts,
        errors: errors
    )
    let firstAttempt = try await performWithRetryAttempt(
        W.self,
        request: try authorizedGET(firstURL),
        attemptBudget: attemptBudget
    )
    let firstPage = firstAttempt.value
    let numberedTemplate = try firstPage.nextPage.flatMap {
        try validatedNextPageURL($0, relativeTo: firstAttempt.responseURL)
    }
    let numberedTemplatePage = numberedTemplate.flatMap(Self.uniqueNumericPageValue)

    // The parallel path speculatively requests pages by number, so a server that
    // clamps an out-of-range `page` to a page that exists can echo rows we already
    // hold. De-duplication by `identity(of:)` is what makes that safe, so a conformer
    // that returns `nil` for any item (the default implementation returns `nil` for
    // all of them) is not eligible: it takes the sequential `next_page` walk, which
    // never requests a page speculatively and so needs no de-duplication. This is the
    // contract `identity(of:)` documents.
    let canDeduplicate = firstPage.pageItems.allSatisfy { W.identity(of: $0) != nil }

    // Validate first-page metadata needed by the selected strategy *before* emitting,
    // so consumers never observe a snapshot from a response we already know is invalid.
    if let total = firstPage.total {
        guard total >= 0 else { throw errors.decode("total out of range: \(total)") }
        if canDeduplicate {
            guard W.pageSize > 0 else {
                throw errors.decode("page size must be positive, got \(W.pageSize)")
            }
        }
    }

    // Fast path eligibility requires the server to advertise an unambiguous numeric
    // page link. A total alone does not make a cursor endpoint page-number capable.
    let considerParallel = firstPage.total != nil && canDeduplicate
        && numberedTemplatePage.map { $0 > 1 } == true

    var estimatedPageCount = 1
    if considerParallel, let total = firstPage.total {
        let pageSize = W.pageSize
        estimatedPageCount = Self.pageCount(total: total, pageSize: pageSize)
        guard estimatedPageCount <= maxParallelPages else {
            throw errors.invalidRequest("Pagination exceeded \(maxParallelPages) parallel pages")
        }
    }

    var visitedPageURLs: Set<URL> = [canonicalPageURL(firstURL)]
    // `seen` de-dupes by each item's stable identity across every page, so an
    // over-requested page that echoes page 1 can't duplicate rows. Only consulted
    // when `canDeduplicate` is true (parallel path).
    var seen = Set<RESTItemIdentity>()
    var items: [W.Item] = []
    Self.appendNew(
        firstPage.pageItems,
        to: &items,
        seen: &seen,
        identity: W.identity(of:),
        deduplicate: canDeduplicate
    )
    emit(items)

    if considerParallel, estimatedPageCount > 1, let total = firstPage.total {
        guard let numberedTemplate else { throw errors.invalidRequest("Invalid pagination template") }
        try await completeParallelPagination(
            W.self,
            firstURL: firstURL,
            numberedTemplate: numberedTemplate,
            total: total,
            pageCount: estimatedPageCount,
            items: &items,
            seen: &seen,
            visitedPageURLs: &visitedPageURLs,
            attemptBudget: attemptBudget,
            emit: emit
        )
        return items
    }

    // Fallback: follow `next_page` one page at a time.
    try await walkNextPages(
        W.self,
        from: firstPage.nextPage,
        relativeTo: firstAttempt.responseURL,
        items: &items,
        seen: &seen,
        visitedPageURLs: &visitedPageURLs,
        pagesAlreadyFetched: 1,
        deduplicate: canDeduplicate,
        attemptBudget: attemptBudget,
        emit: emit
    )
    return items
}

/// Parallel numbered pages, then any `next_page` remainder past the estimate.
nonisolated func completeParallelPagination<W: PagedResponse>(
    _: W.Type,
    firstURL: URL,
    numberedTemplate: URL,
    total: Int,
    pageCount: Int,
    items: inout [W.Item],
    seen: inout Set<RESTItemIdentity>,
    visitedPageURLs: inout Set<URL>,
    attemptBudget: PaginationHTTPAttemptBudget,
    emit: @Sendable ([W.Item]) -> Void
) async throws {
    func numberedPageURL(_ page: Int?) -> URL? {
        guard let page else { return firstURL }
        guard let overlaid = Self.overlayingPercentEncodedQuery(
            from: numberedTemplate,
            onto: firstURL
        ) else { return nil }
        return Self.replacingPercentEncodedQueryFields(
            in: overlaid,
            replacements: [(name: "page", value: String(page))]
        )
    }
    let (tailNextPage, tailResponseURL) = try await fetchKnownPages(
        W.self,
        total: total,
        pageCount: pageCount,
        items: &items,
        seen: &seen,
        pageURL: numberedPageURL,
        attemptBudget: attemptBudget,
        emit: emit
    )
    for page in 2 ... pageCount {
        if let url = numberedPageURL(page) {
            visitedPageURLs.insert(canonicalPageURL(url))
        }
    }
    try await walkNextPages(
        W.self,
        from: tailNextPage,
        relativeTo: tailResponseURL,
        items: &items,
        seen: &seen,
        visitedPageURLs: &visitedPageURLs,
        pagesAlreadyFetched: pageCount,
        deduplicate: true,
        attemptBudget: attemptBudget,
        emit: emit
    )
}

/// Counts HTTP attempts for one paginated list so retries cannot amplify page caps (#123).
nonisolated final class PaginationHTTPAttemptBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let limit: Int
    private let errors: any RESTTransportErrorMapping

    nonisolated init(limit: Int, errors: any RESTTransportErrorMapping) {
        self.remaining = limit
        self.limit = limit
        self.errors = errors
    }

    nonisolated func consume() throws {
        try lock.withLock {
            guard remaining > 0 else {
                throw errors.invalidRequest(
                    "Pagination exceeded \(limit) HTTP attempts (pages × retries)"
                )
            }
            remaining -= 1
        }
    }
}

/// Appends items, optionally de-duplicating by `PagedResponse` identity. When
/// `deduplicate` is false (the nil-identity sequential path), every item is kept -
/// including repeats of non-nil identities - matching the protocol contract that
/// opting out of identity routes the list where de-duplication isn't applied.
@discardableResult
nonisolated static func appendNew<Item>(
    _ newItems: [Item],
    to items: inout [Item],
    seen: inout Set<RESTItemIdentity>,
    identity: (Item) -> RESTItemIdentity?,
    deduplicate: Bool
) -> Int {
    guard deduplicate else {
        items.append(contentsOf: newItems)
        return newItems.count
    }

    var appended = 0
    for item in newItems {
        guard let key = identity(item) else { items.append(item); appended += 1; continue }

        if seen.insert(key).inserted { items.append(item); appended += 1 }
    }
    return appended
}

/// Speculative parallel page slot: either a loaded page or a stale-total 404 gap.
private enum ParallelPendingPage<Page> {
    case loaded(page: Page, responseURL: URL)
    /// Speculative page past the live list (stale `total`); keep prior records.
    case missing
}

/// Outcome of one speculative parallel page request.
private enum ParallelPageFetchOutcome<Page: Sendable>: Sendable {
    case success(Int, Page, URL)
    case notFound(Int)
}

/// Fetches pages 2…N concurrently (bounded window), appending each completed page in
/// contiguous order and emitting a snapshot whenever the ordered prefix grows. Returns
/// the `next_page` of the final estimated page when that page was in range, so the
/// caller can pick up any remainder, and `nil` when there is nothing left to walk.
nonisolated func fetchKnownPages<W: PagedResponse>(
    _: W.Type,
    total _: Int,
    pageCount: Int,
    items: inout [W.Item],
    seen: inout Set<RESTItemIdentity>,
    pageURL: (Int?) -> URL?,
    attemptBudget: PaginationHTTPAttemptBudget,
    emit: @Sendable ([W.Item]) -> Void
) async throws -> (nextPage: String?, responseURL: URL) {
    // `total` is a lower bound on the page count: it can undercount if records are
    // created mid-load. So fetch pages 2…N in parallel, then follow `next_page` from
    // the final page to pick up any remainder rather than silently dropping records
    // past the estimate.
    //
    // Metadata (page size, total range, derived page count) was already validated in
    // `drivePagination` before the first snapshot was emitted.
    guard pageCount > 1 else { return (nil, pageURL(1) ?? baseURL) }

    // Only the final page's `next_page` is worth following. A server that clamps an
    // out-of-range `page` returns an already-seen page whose `next_page` points back into
    // the numbered range; `advancingTailNextPage` rejects that without confusing it with
    // a legitimate duplicate-only page caused by concurrent list drift.
    var tailNextPage: String?
    var tailResponseURL = pageURL(pageCount) ?? baseURL
    var pending: [Int: ParallelPendingPage<W>] = [:]
    var nextToEmit = 2
    var collected = items
    try await withThrowingTaskGroup(of: ParallelPageFetchOutcome<W>.self) { group in
        func enqueue(_ page: Int) throws {
            guard let url = pageURL(page) else { throw errors.invalidRequest("Invalid URL") }

            group.addTask {
                do {
                    let attempt = try await performWithRetryAttempt(
                        W.self,
                        request: try authorizedGET(url),
                        attemptBudget: attemptBudget
                    )
                    return .success(page, attempt.value, attempt.responseURL)
                } catch {
                    // Stale high `total` requests pages that no longer exist (#171).
                    if Self.isNotFoundHTTPError(error) {
                        return .notFound(page)
                    }
                    throw error
                }
            }
        }
        // Keep a bounded window in flight - enough to saturate the network without
        // unleashing dozens of connections (which invite 429s).
        let maxConcurrent = 8
        var nextToFetch = 2
        while nextToFetch <= pageCount, nextToFetch - 2 < maxConcurrent {
            try enqueue(nextToFetch); nextToFetch += 1
        }
        do {
            while let fetch = try await group.next() {
                switch fetch {
                case let .success(page, response, responseURL):
                    // Reject malformed speculative pages as soon as they finish. Waiting for a
                    // missing earlier page used to retain invalid responses in `pending` and delay
                    // the failure unnecessarily.
                    try validateParallelIdentities(response)
                    pending[page] = .loaded(page: response, responseURL: responseURL)
                case let .notFound(page):
                    pending[page] = .missing
                }
                // Emit a new snapshot whenever the contiguous prefix grows.
                var grew = false
                var reachedDeclaredEnd = false
                while let ready = pending.removeValue(forKey: nextToEmit) {
                    switch ready {
                    case .missing:
                        // Preceding contiguous pages are authoritative; drop speculative 404s.
                        reachedDeclaredEnd = true
                        pending.removeAll()
                    case let .loaded(response, responseURL):
                        let added = Self.appendNew(
                            response.pageItems,
                            to: &collected,
                            seen: &seen,
                            identity: W.identity(of:),
                            deduplicate: true
                        )
                        // The final page's `next_page` tells us whether the estimate fell
                        // short. A duplicate-only page can still be genuinely in range after
                        // concurrent insert/delete drift, so do not require it to add rows.
                        // Reject only links that point back into the already fetched numbered
                        // range, which is how an out-of-range request clamped to page one shows
                        // up here.
                        if nextToEmit == pageCount {
                            tailResponseURL = responseURL
                            tailNextPage = try advancingTailNextPage(
                                response.nextPage,
                                afterEstimatedPage: pageCount,
                                pageAddedItems: added,
                                relativeTo: responseURL
                            )
                        } else if response.nextPage == nil {
                            // An ordered intermediate page is authoritative. Requests beyond it
                            // were speculative and their rows must not enter the result.
                            reachedDeclaredEnd = true
                            pending.removeAll()
                        }
                        nextToEmit += 1
                        grew = grew || added > 0
                    }
                    if reachedDeclaredEnd { break }
                }
                if grew { emit(collected) }
                if reachedDeclaredEnd {
                    group.cancelAll()
                    break
                }
                // Bound how far completed pages can get ahead of the next ordered page.
                // A slow early page therefore cannot allow the whole list to accumulate.
                while nextToFetch <= pageCount, nextToFetch < nextToEmit + maxConcurrent {
                    try enqueue(nextToFetch)
                    nextToFetch += 1
                }
            }
        } catch {
            group.cancelAll()
            throw error
        }
    }
    items = collected
    return (tailNextPage, tailResponseURL)
}

nonisolated static func isNotFoundHTTPError(_ error: any Error) -> Bool {
    let detail = String(describing: error)
    if detail.contains("404") && detail.lowercased().contains("http") {
        return true
    }
    // Mirror common client mappings such as `.http(404)` / `http status 404`.
    return detail.contains("(404)") || detail.hasSuffix("404")
}

nonisolated func advancingTailNextPage(
    _ value: String?,
    afterEstimatedPage pageCount: Int,
    pageAddedItems: Int,
    relativeTo pageURL: URL
) throws -> String? {
    guard let value, let url = try validatedNextPageURL(value, relativeTo: pageURL) else {
        return nil
    }
    let pageValues = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .filter { $0.name == "page" }
        .compactMap(\.value) ?? []
    guard pageValues.count <= 1 else {
        throw errors.invalidRequest("Pagination next_page contains duplicate page parameters")
    }
    guard let pageValue = pageValues.first else { return value }

    // Non-numeric cursor values are followed as-is. Numeric literals must parse and
    // advance past the estimate; overflow, non-positive, and backward values fail.
    guard Self.isDecimalIntegerLiteral(pageValue) else { return value }

    guard let page = Int(pageValue) else {
        throw errors.invalidRequest("Pagination next_page page value out of range")
    }
    guard page > 0 else {
        throw errors.invalidRequest("Pagination next_page page must be positive")
    }
    if page <= pageCount {
        // Duplicate-only final page with a link back into the numbered range is the
        // common out-of-range clamp; treat it as end-of-list. A page that contributed
        // new rows with a backward link is corrupt metadata - surface it.
        if pageAddedItems == 0 { return nil }
        throw errors.invalidRequest("Pagination next_page cycle detected")
    }
    return value
}

nonisolated func validateParallelIdentities<W: PagedResponse>(_ page: W) throws {
    guard page.pageItems.allSatisfy({ W.identity(of: $0) != nil }) else {
        throw errors.decode("parallel pagination requires a stable identity for every item")
    }
}

/// Walks `next_page` links one page at a time, appending and emitting each page.
/// Used for the fallback path and to pick up any remainder past a parallel estimate.
nonisolated func walkNextPages<W: PagedResponse>(
    _: W.Type,
    from start: String?,
    relativeTo startBase: URL,
    items: inout [W.Item],
    seen: inout Set<RESTItemIdentity>,
    visitedPageURLs: inout Set<URL>,
    pagesAlreadyFetched: Int,
    deduplicate: Bool,
    attemptBudget: PaginationHTTPAttemptBudget,
    emit: @Sendable ([W.Item]) -> Void
) async throws {
    var url = try start.flatMap { try validatedNextPageURL($0, relativeTo: startBase) }
    var pagesFetched = pagesAlreadyFetched
    while let current = url {
        guard pagesFetched < maxSequentialPages else {
            throw errors.invalidRequest("Pagination exceeded \(maxSequentialPages) total pages")
        }
        guard visitedPageURLs.insert(canonicalPageURL(current)).inserted else {
            throw errors.invalidRequest("Pagination next_page cycle detected")
        }

        let attempt = try await performWithRetryAttempt(
            W.self,
            request: try authorizedGET(current),
            attemptBudget: attemptBudget
        )
        let page = attempt.value
        let added = Self.appendNew(
            page.pageItems,
            to: &items,
            seen: &seen,
            identity: W.identity(of:),
            deduplicate: deduplicate
        )
        if added > 0 { emit(items) }
        pagesFetched += 1
        guard let next = page.nextPage else { break }

        // Safety valve against a server that keeps handing back next_page links.
        // The initial page counts toward the limit. Surface the cap as an error
        // rather than silently truncating the list.
        guard pagesFetched < maxSequentialPages else {
            throw errors.invalidRequest("Pagination exceeded \(maxSequentialPages) sequential pages")
        }

        let nextURL = try validatedNextPageURL(next, relativeTo: attempt.responseURL)
        guard let nextURL else { break }
        url = nextURL
    }
}

/// Resolves a response-provided pagination link without granting it authority to choose
/// where the bearer credential is sent. Relative references resolve against the URL of
/// the response that supplied them (RFC 3986), while every absolute result must remain
/// on the configured HTTP(S) origin.
nonisolated func validatedNextPageURL(_ value: String, relativeTo pageURL: URL) throws -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let resolved = URL(string: trimmed, relativeTo: pageURL)?.absoluteURL else {
        throw errors.invalidRequest("Invalid pagination next_page")
    }

    guard let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
          let candidate = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
          let baseScheme = base.scheme?.lowercased(),
          let candidateScheme = candidate.scheme?.lowercased(),
          ["http", "https"].contains(baseScheme),
          candidateScheme == baseScheme,
          let baseHost = base.host?.lowercased(),
          candidate.host?.lowercased() == baseHost,
          effectivePort(candidate) == effectivePort(base),
          candidate.user == nil,
          candidate.password == nil
    else {
        throw errors.invalidRequest("Pagination next_page left the configured origin")
    }

    return resolved
}

nonisolated func effectivePort(_ components: URLComponents) -> Int? {
    components.port ?? defaultPort(for: components.scheme)
}

nonisolated func defaultPort(for scheme: String?) -> Int? {
    switch scheme?.lowercased() {
    case "http": 80
    case "https": 443
    default: nil
    }
}

/// Produces the identity used for cycle detection. URL fragments never reach an HTTP
/// server, and origin spelling differences must not let the same page evade the guard.
nonisolated func canonicalPageURL(_ url: URL) -> URL {
    let standardized = url.standardized
    guard var components = URLComponents(url: standardized, resolvingAgainstBaseURL: false) else {
        return standardized
    }

    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    if components.port == defaultPort(for: components.scheme) { components.port = nil }
    components.fragment = nil
    // Reordered query forms must share one identity so cycle detection cannot be evaded
    // by superficial URL spelling differences. Assigning `queryItems` also normalizes
    // equivalent percent-encoding when the URL is rebuilt.
    if let items = components.queryItems, !items.isEmpty {
        components.queryItems = items.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return ($0.value ?? "") < ($1.value ?? "")
        }
    }
    return components.url?.standardized ?? standardized
}
}
