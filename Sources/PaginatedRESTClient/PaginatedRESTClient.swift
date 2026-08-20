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
    nonisolated static func identity(of item: Item) -> AnyHashable?
}

public extension PagedResponse {
    nonisolated static var pageSize: Int {
        100
    }

    nonisolated static func identity(of _: Item) -> AnyHashable? {
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

/// Injectable sources used by retry tests. Production clients use wall-clock time,
/// cancellable `Task.sleep`, and system randomness.
nonisolated struct RetryRuntime: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let jitter: @Sendable () -> Double

    static let live = RetryRuntime(
        now: Date.init,
        sleep: { delay in try await Task.sleep(for: .seconds(delay)) },
        jitter: { Double.random(in: 0 ... 1) }
    )
}

/// A client-wide rate-limit deadline. A lock keeps the fast preflight check synchronous
/// while allowing every concurrent pagination task to publish and observe one cooldown.
nonisolated final class RateLimitCooldown: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date?

    func extend(until candidate: Date) {
        lock.withLock {
            if deadline.map({ candidate > $0 }) ?? true { deadline = candidate }
        }
    }

    func remaining(at now: Date) -> TimeInterval? {
        lock.withLock {
            guard let deadline else { return nil }
            let delay = deadline.timeIntervalSince(now)
            return delay > 0 ? delay : nil
        }
    }
}

/// Keeps the mapped client error private while retaining the HTTP response for retry
/// decisions. Public `perform` unwraps this before returning an error to its caller.
private nonisolated struct HTTPAttemptFailure: Error {
    let response: RESTResponse
    let mappedError: any Error
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
    nonisolated static let maxRetryDelay: TimeInterval = 60

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
        maxParallelPages: Int = Self.defaultMaxParallelPages
    ) {
        self.init(
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport,
            decoderFactory: decoderFactory,
            encoderFactory: encoderFactory,
            errors: errors,
            log: log,
            retryRuntime: .live,
            maxSequentialPages: maxSequentialPages,
            maxParallelPages: maxParallelPages
        )
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
            rateLimitCooldown: other.rateLimitCooldown
        )
    }

    public nonisolated func fetch<T: Decodable & Sendable>(_ type: T.Type, path: String) async throws -> T {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }

        return try await performWithRetry(type, request: try authorizedGET(baseURL.appending(path: path)))
    }

    /// Accumulates every page of a paginated list endpoint. Convenience over
    /// `streamAllPages` for callers that only want the final, complete list.
    public nonisolated func fetchAllPages<W: PagedResponse>(
        _: W.Type,
        path: String,
        sort: String? = nil
    ) async throws -> [W.Item] {
        var items: [W.Item] = []
        for try await snapshot in streamAllPages(W.self, path: path, sort: sort) {
            items = snapshot
        }
        return items
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
    ) -> AsyncThrowingStream<[W.Item], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // This method is `nonisolated`, and so is the networking it calls, so this
            // unstructured `Task` does not inherit the module's default main-actor
            // isolation - the pipeline, including the concurrent child tasks below,
            // runs on the cooperative pool. That keeps the list-building work (URL
            // construction, snapshot accumulation) off the main thread while pages
            // stream in. The `nonisolated` on *this* method is what makes that true:
            // `AsyncThrowingStream`'s build closure is non-`Sendable` and non-escaping,
            // so it inherits the enclosing isolation, and a plain `Task` created from a
            // MainActor-isolated context inherits the main actor regardless of
            // Sendability. With `NonisolatedNonsendingByDefault` the `nonisolated` async
            // callees then run on *this* task's executor, so they stay off the main
            // actor too.
            let work = Task {
                do {
                    try await drivePagination(W.self, path: path, sort: sort) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
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
        maxAttempts: Int = 3
    ) async throws -> T {
        guard maxAttempts > 0 else { throw errors.decode("maxAttempts must be positive") }
        guard Self.methodIsIdempotent(request.method) else {
            return try await perform(type, request: request)
        }
        let attempts = request.bodyFileURL == nil ? maxAttempts : 1

        var attempt = 0
        while true {
            do {
                return try await performAttempt(type, request: request)
            } catch let failure as HTTPAttemptFailure {
                attempt += 1

                if failure.response.statusCode == 429 {
                    guard attempt < attempts, errors.isTransient(failure.mappedError) else {
                        throw failure.mappedError
                    }
                    let now = retryRuntime.now()
                    let retryAfter = Self.retryAfterDelay(
                        failure.response.value(forHTTPHeaderField: "Retry-After"),
                        relativeTo: now
                    )
                    let delay = min(Self.maxRetryDelay, retryAfter ?? Self.rateLimitFallbackDelay(
                        retryNumber: attempt,
                        jitter: retryRuntime.jitter()
                    ))
                    rateLimitCooldown.extend(until: now.addingTimeInterval(delay))
                    emitLog(
                        "Rate limited; retry \(attempt)/\(attempts - 1) "
                            + "after shared \(String(format: "%.3f", delay))s cooldown"
                    )
                    try await waitForRateLimitCooldown()
                    continue
                }

                guard attempt < attempts, errors.isTransient(failure.mappedError) else {
                    throw failure.mappedError
                }

                if Self.honorsRetryAfter(statusCode: failure.response.statusCode),
                   let retryAfter = Self.retryAfterDelay(
                       failure.response.value(forHTTPHeaderField: "Retry-After"),
                       relativeTo: retryRuntime.now()
                   ) {
                    let delay = min(Self.maxRetryDelay, retryAfter)
                    emitLog(
                        "Transient failure; retry \(attempt)/\(attempts - 1) "
                            + "after \(String(format: "%.3f", delay))s Retry-After"
                    )
                    try await retryRuntime.sleep(delay)
                    continue
                }

                emitLog("Transient failure; retry \(attempt)/\(attempts - 1)")
                try await retryRuntime.sleep(Self.retryBackoffDelay(retryNumber: attempt))
            } catch is CancellationError {
                throw CancellationError()
            } catch let bodyError as RESTRequestBodyError {
                throw mappedBodyError(bodyError)
            } catch {
                attempt += 1
                guard attempt < attempts, errors.isTransient(error) else { throw error }

                emitLog("Transient failure; retry \(attempt)/\(attempts - 1)")
                // Preserve the existing 300ms, then 600ms exponential policy for
                // non-HTTP transient errors. The injected sleep remains cancellable.
                try await retryRuntime.sleep(Self.retryBackoffDelay(retryNumber: attempt))
            }
        }
    }

    public nonisolated func send<T: Decodable & Sendable>(
        _ type: T.Type,
        method: String,
        path: String,
        body: some Encodable
    ) async throws -> T {
        try await perform(type, request: try makeSendRequest(method: method, path: path, body: body))
    }

    /// Sends a JSON body when the response has no model (for example HTTP 204/205).
    public nonisolated func send(
        method: String,
        path: String,
        body: some Encodable
    ) async throws {
        try await performNoContent(request: try makeSendRequest(method: method, path: path, body: body))
    }

    public nonisolated func perform<T: Decodable & Sendable>(
        _ type: T.Type,
        request: RESTRequest
    ) async throws -> T {
        do {
            return try await performAttempt(type, request: request)
        } catch let failure as HTTPAttemptFailure {
            observeRateLimitCooldown(from: failure.response)
            throw failure.mappedError
        } catch let bodyError as RESTRequestBodyError {
            throw mappedBodyError(bodyError)
        }
    }

    private nonisolated func performAttempt<T: Decodable & Sendable>(
        _ type: T.Type,
        request: RESTRequest
    ) async throws -> T {
        let response = try await transportResponse(for: request)
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
            return try await decodeInBackground(T.self, from: response.data)
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

    private nonisolated func transportResponse(for request: RESTRequest) async throws -> RESTResponse {
        try await waitForRateLimitCooldown()
        try Task.checkCancellation()

        do {
            return try await transport.response(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let overflow as RESTResponseTooLargeError {
            throw mappedOverflow(overflow)
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
    private nonisolated func observeRateLimitCooldown(from response: RESTResponse) {
        guard response.statusCode == 429 else { return }
        let now = retryRuntime.now()
        let retryAfter = Self.retryAfterDelay(
            response.value(forHTTPHeaderField: "Retry-After"),
            relativeTo: now
        )
        let delay = min(
            Self.maxRetryDelay,
            retryAfter ?? Self.rateLimitFallbackDelay(retryNumber: 1, jitter: retryRuntime.jitter())
        )
        rateLimitCooldown.extend(until: now.addingTimeInterval(delay))
    }

    private nonisolated func mappedBodyError(_ error: RESTRequestBodyError) -> any Error {
        errors.invalidRequest(Self.describeBodyError(error))
    }

    private nonisolated func makeSendRequest(
        method: String,
        path: String,
        body: some Encodable
    ) throws -> RESTRequest {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }
        guard Self.methodAllowsJSONBody(method) else {
            throw errors.invalidRequest(
                "send requires a method that allows a JSON body; use fetch for GET/HEAD"
            )
        }
        let url = try validatedAuthenticatedURL(baseURL.appending(path: path))
        let encoded: Data
        do {
            encoded = try encoderFactory().encode(body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw errors.encode(Self.boundedEncodeDetail(error))
        }
        return RESTRequest(
            url: url,
            method: method,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            body: encoded
        )
    }

    /// Waits against the latest shared deadline. The loop matters when a sibling receives
    /// a later `Retry-After` while this task is already sleeping.
    private nonisolated func waitForRateLimitCooldown() async throws {
        while let delay = rateLimitCooldown.remaining(at: retryRuntime.now()) {
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
    /// A structured child task (not `Task.detached`) so it inherits cancellation: when a
    /// streaming load is torn down, queued decodes bail at the check below instead of
    /// parsing into a result that's about to be discarded. This function is `nonisolated`,
    /// so the task still runs off the main actor.
    private nonisolated func decodeInBackground<T: Decodable & Sendable>(
        _: T.Type,
        from data: Data
    ) async throws -> T {
        let make = decoderFactory
        return try await Task(priority: .userInitiated) {
            try Task.checkCancellation()
            return try make().decode(T.self, from: data)
        }.value
    }
}

extension PaginatedRESTClient {
    /// Parses RFC delay-seconds and all three HTTP-date forms. A date in the past is a
    /// valid instruction to retry immediately; malformed and negative values fall back.
    nonisolated static func retryAfterDelay(_ value: String?, relativeTo now: Date) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII),
           trimmed.allSatisfy(\.isNumber), let seconds = TimeInterval(trimmed), seconds.isFinite {
            return seconds
        }

        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: trimmed) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
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
        // Incomplete sequence at the cut: drop the lead byte.
        if end - 1 + needed > maxBytes {
            end -= 1
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
        return min(maxRetryDelay, 0.3 * pow(2, exponent))
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
}

public extension PaginatedRESTClient {
    /// Builds an authenticated GET only for the configured origin. This method throws
    /// rather than placing bearer credentials on an arbitrary caller-provided URL.
    nonisolated func authorizedGET(_ url: URL) throws -> RESTRequest {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }
        let validated = try validatedAuthenticatedURL(url)
        return RESTRequest(
            url: validated,
            method: "GET",
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
        )
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

    /// Executes a request that has no response model. Any 2xx response succeeds,
    /// whether its body is empty (including 204) or contains optional server metadata.
    nonisolated func performNoContent(request: RESTRequest) async throws {
        do {
            let response = try await transportResponse(for: request)
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
            observeRateLimitCooldown(from: failure.response)
            throw failure.mappedError
        } catch let bodyError as RESTRequestBodyError {
            throw mappedBodyError(bodyError)
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
}

// MARK: - Pagination pipeline

/// The multi-page machinery: path selection, ordered stitching, and the two page-walking
/// strategies. Split into its own extension so the type above stays the client surface
/// (configuration, single requests, retry) and this stays the pagination algorithm.
private extension PaginatedRESTClient {
/// Drives the page-by-page fetch, calling `emit` with each cumulative snapshot.
/// Splits into the parallel "fast path" (when `total` is known) and the
/// sequential `next_page` walk, both extracted into helpers below.
nonisolated func drivePagination<W: PagedResponse>(
    _: W.Type,
    path: String,
    sort: String?,
    emit: ([W.Item]) -> Void
) async throws {
    guard !apiKey.isEmpty else { throw errors.missingAPIKey() }

    /// Builds `…/path?sort=…&page=N`. Page numbers are constructed here
    /// rather than taken from `next_page` so the parallel fetch is
    /// fully deterministic. An intentional initial `page` query on the
    /// configured URL is preserved when no replacement page is supplied.
    func pageURL(_ page: Int?) -> URL? {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        var query = comps?.queryItems ?? []
        if let sort {
            query.removeAll { $0.name.compare("sort", options: .caseInsensitive) == .orderedSame }
            query.append(URLQueryItem(name: "sort", value: sort))
        }
        if let page {
            query.removeAll { $0.name.compare("page", options: .caseInsensitive) == .orderedSame }
            query.append(URLQueryItem(name: "page", value: String(page)))
        }
        comps?.queryItems = query.isEmpty ? nil : query
        return comps?.url
    }

    guard let firstURL = pageURL(nil) else { throw errors.invalidRequest("Invalid URL") }

    let firstPage = try await performWithRetry(W.self, request: try authorizedGET(firstURL))

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
    }

    // Fast path eligibility: known total + stable identities. A nonempty first page
    // with `next_page == nil` is an authoritative end-of-list even when `total`
    // suggests more pages - do not speculate. An *empty* first page may still use
    // total/page-size to reach later numbered pages (filtered window).
    let considerParallel = firstPage.total != nil && canDeduplicate
        && (firstPage.nextPage != nil || firstPage.pageItems.isEmpty)

    var estimatedPageCount = 1
    if considerParallel, let total = firstPage.total {
        let pageSize = W.pageSize
        guard pageSize > 0 else { throw errors.decode("page size must be positive, got \(pageSize)") }
        estimatedPageCount = Self.pageCount(total: total, pageSize: pageSize)
        guard estimatedPageCount <= maxParallelPages else {
            throw errors.invalidRequest("Pagination exceeded \(maxParallelPages) parallel pages")
        }
    }

    var visitedPageURLs: Set<URL> = [canonicalPageURL(firstURL)]
    // `seen` de-dupes by each item's stable identity across every page, so an
    // over-requested page that echoes page 1 can't duplicate rows. Only consulted
    // when `canDeduplicate` is true (parallel path).
    var seen = Set<AnyHashable>()
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
        let tailNextPage = try await fetchKnownPages(
            W.self,
            total: total,
            pageCount: estimatedPageCount,
            items: &items,
            seen: &seen,
            pageURL: pageURL,
            emit: emit
        )
        let finalEstimatedURL = pageURL(estimatedPageCount) ?? firstURL
        try await walkNextPages(
            W.self,
            from: tailNextPage,
            relativeTo: finalEstimatedURL,
            items: &items,
            seen: &seen,
            visitedPageURLs: &visitedPageURLs,
            pagesAlreadyFetched: estimatedPageCount,
            deduplicate: true,
            emit: emit
        )
        return
    }

    // Fallback: follow `next_page` one page at a time.
    try await walkNextPages(
        W.self,
        from: firstPage.nextPage,
        relativeTo: firstURL,
        items: &items,
        seen: &seen,
        visitedPageURLs: &visitedPageURLs,
        pagesAlreadyFetched: 1,
        deduplicate: canDeduplicate,
        emit: emit
    )
}

/// Appends items, optionally de-duplicating by `PagedResponse` identity. When
/// `deduplicate` is false (the nil-identity sequential path), every item is kept -
/// including repeats of non-nil identities - matching the protocol contract that
/// opting out of identity routes the list where de-duplication isn't applied.
@discardableResult
nonisolated static func appendNew<Item>(
    _ newItems: [Item],
    to items: inout [Item],
    seen: inout Set<AnyHashable>,
    identity: (Item) -> AnyHashable?,
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

/// Fetches pages 2…N concurrently (bounded window), appending each completed page in
/// contiguous order and emitting a snapshot whenever the ordered prefix grows. Returns
/// the `next_page` of the final estimated page when that page was in range, so the
/// caller can pick up any remainder, and `nil` when there is nothing left to walk.
nonisolated func fetchKnownPages<W: PagedResponse>(
    _: W.Type,
    total _: Int,
    pageCount: Int,
    items: inout [W.Item],
    seen: inout Set<AnyHashable>,
    pageURL: (Int?) -> URL?,
    emit: ([W.Item]) -> Void
) async throws -> String? {
    // `total` is a lower bound on the page count: it can undercount if records are
    // created mid-load. So fetch pages 2…N in parallel, then follow `next_page` from
    // the final page to pick up any remainder rather than silently dropping records
    // past the estimate.
    //
    // Metadata (page size, total range, derived page count) was already validated in
    // `drivePagination` before the first snapshot was emitted.
    guard pageCount > 1 else { return nil }

    // Only the final page's `next_page` is worth following. A server that clamps an
    // out-of-range `page` returns an already-seen page whose `next_page` points back into
    // the numbered range; `advancingTailNextPage` rejects that without confusing it with
    // a legitimate duplicate-only page caused by concurrent list drift.
    var tailNextPage: String?
    var pending: [Int: W] = [:]
    var nextToEmit = 2
    var collected = items
    try await withThrowingTaskGroup(of: (Int, W).self) { group in
        func enqueue(_ page: Int) throws {
            guard let url = pageURL(page) else { throw errors.invalidRequest("Invalid URL") }

            group.addTask {
                try await (page, performWithRetry(W.self, request: try authorizedGET(url)))
            }
        }
        // Keep a bounded window in flight - enough to saturate the network without
        // unleashing dozens of connections (which invite 429s).
        let maxConcurrent = 8
        var nextToFetch = 2
        while nextToFetch <= pageCount, nextToFetch - 2 < maxConcurrent {
            try enqueue(nextToFetch); nextToFetch += 1
        }
        while let (page, response) = try await group.next() {
            pending[page] = response
            // Emit a new snapshot whenever the contiguous prefix grows.
            var grew = false
            while let ready = pending.removeValue(forKey: nextToEmit) {
                try validateParallelIdentities(ready)
                let added = Self.appendNew(
                    ready.pageItems,
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
                    let finalURL = pageURL(pageCount) ?? baseURL
                    tailNextPage = try advancingTailNextPage(
                        ready.nextPage,
                        afterEstimatedPage: pageCount,
                        pageAddedItems: added,
                        relativeTo: finalURL
                    )
                }
                nextToEmit += 1
                grew = grew || added > 0
            }
            if grew { emit(collected) }
            if nextToFetch <= pageCount { try enqueue(nextToFetch); nextToFetch += 1 }
        }
    }
    items = collected
    return tailNextPage
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
    let pageValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name.compare("page", options: .caseInsensitive) == .orderedSame }?
        .value

    guard let pageValue else { return value }

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
    seen: inout Set<AnyHashable>,
    visitedPageURLs: inout Set<URL>,
    pagesAlreadyFetched: Int,
    deduplicate: Bool,
    emit: ([W.Item]) -> Void
) async throws {
    var previousURL = startBase
    var url = try start.flatMap { try validatedNextPageURL($0, relativeTo: previousURL) }
    var pagesFetched = pagesAlreadyFetched
    while let current = url {
        guard visitedPageURLs.insert(canonicalPageURL(current)).inserted else {
            throw errors.invalidRequest("Pagination next_page cycle detected")
        }

        let page = try await performWithRetry(W.self, request: try authorizedGET(current))
        Self.appendNew(
            page.pageItems,
            to: &items,
            seen: &seen,
            identity: W.identity(of:),
            deduplicate: deduplicate
        )
        emit(items)
        pagesFetched += 1
        guard let next = page.nextPage else { break }

        // Safety valve against a server that keeps handing back next_page links.
        // The initial page counts toward the limit. Surface the cap as an error
        // rather than silently truncating the list.
        guard pagesFetched < maxSequentialPages else {
            throw errors.invalidRequest("Pagination exceeded \(maxSequentialPages) sequential pages")
        }

        let nextURL = try validatedNextPageURL(next, relativeTo: current)
        guard let nextURL else { break }
        previousURL = current
        url = nextURL
    }
}

/// Resolves a response-provided pagination link without granting it authority to choose
/// where the bearer credential is sent. Relative references resolve against the URL of
/// the response that supplied them (RFC 3986), while every absolute result must remain
/// on the configured HTTP(S) origin.
nonisolated func validatedNextPageURL(_ value: String, relativeTo pageURL: URL) throws -> URL? {
    guard !value.isEmpty else { return nil }
    guard let resolved = URL(string: value, relativeTo: pageURL)?.absoluteURL else {
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
    return components.url?.standardized ?? standardized
}
}
