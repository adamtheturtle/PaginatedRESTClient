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
/// supply an absolute `next_page` URL when more remain. Callers that ignore it silently
/// see only the first page.
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
    /// Whether an error already produced by this mapping should be retried.
    nonisolated func isTransient(_ error: Error) -> Bool
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
private nonisolated final class RateLimitCooldown: @unchecked Sendable {
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
    nonisolated let log: @Sendable (String) -> Void
    private nonisolated let retryRuntime: RetryRuntime
    private nonisolated let rateLimitCooldown: RateLimitCooldown

    /// Upper bound on `next_page` follows for one list, guarding against a server
    /// that keeps handing back links. Hitting it throws rather than truncating.
    nonisolated static let maxSequentialPages = 1000

    /// Upper bound on pages the parallel path will request for one list, mirroring
    /// `maxSequentialPages`. The page count there is derived from a server-supplied
    /// `total`, so without a valve a single bogus `total` turns one `fetchAllPages`
    /// call into thousands of requests. Hitting it throws rather than truncating.
    nonisolated static let maxParallelPages = 1000

    /// Upper bound on a server-reported `total`, checked before it reaches the page-count
    /// arithmetic. `total` is decoded straight from JSON, so a hostile or malformed
    /// response could otherwise overflow `total + pageSize - 1` and trap the process.
    nonisolated static let maxReportedTotal = 100_000_000

    /// Retry delays, including server-provided `Retry-After` values, never block the
    /// shared client for longer than one minute.
    nonisolated static let maxRetryDelay: TimeInterval = 60

    public init(
        apiKey: String,
        baseURL: URL,
        transport: any RESTTransport = URLSessionTransport(),
        decoderFactory: @escaping @Sendable () -> JSONDecoder,
        encoderFactory: @escaping @Sendable () -> JSONEncoder,
        errors: any RESTTransportErrorMapping,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport,
            decoderFactory: decoderFactory,
            encoderFactory: encoderFactory,
            errors: errors,
            log: log,
            retryRuntime: .live
        )
    }

    init(
        apiKey: String,
        baseURL: URL,
        transport: any RESTTransport,
        decoderFactory: @escaping @Sendable () -> JSONDecoder,
        encoderFactory: @escaping @Sendable () -> JSONEncoder,
        errors: any RESTTransportErrorMapping,
        log: @escaping @Sendable (String) -> Void = { _ in },
        retryRuntime: RetryRuntime
    ) {
        self.apiKey = Self.normalizedAPIKey(apiKey) ?? ""
        self.baseURL = baseURL
        self.transport = transport
        self.decoderFactory = decoderFactory
        self.encoderFactory = encoderFactory
        self.errors = errors
        self.log = log
        self.retryRuntime = retryRuntime
        rateLimitCooldown = RateLimitCooldown()
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
    public nonisolated func performWithRetry<T: Decodable & Sendable>(
        _ type: T.Type,
        request: RESTRequest,
        maxAttempts: Int = 3
    ) async throws -> T {
        guard maxAttempts > 0 else { throw errors.decode("maxAttempts must be positive") }
        guard Self.methodIsIdempotent(request.method) else {
            return try await perform(type, request: request)
        }

        var attempt = 0
        while true {
            do {
                return try await performAttempt(type, request: request)
            } catch let failure as HTTPAttemptFailure {
                attempt += 1

                if failure.response.statusCode == 429 {
                    guard attempt < maxAttempts, errors.isTransient(failure.mappedError) else {
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
                    log("Rate limited on \(request.url.path); retry \(attempt)/\(maxAttempts - 1) "
                        + "after shared \(String(format: "%.3f", delay))s cooldown")
                    try await waitForRateLimitCooldown()
                    continue
                }

                guard attempt < maxAttempts, errors.isTransient(failure.mappedError) else {
                    throw failure.mappedError
                }
                log("Transient failure on \(request.url.path); retry \(attempt)/\(maxAttempts - 1)")
                try await retryRuntime.sleep(Self.retryBackoffDelay(retryNumber: attempt))
            } catch {
                attempt += 1
                guard attempt < maxAttempts, errors.isTransient(error) else { throw error }

                log("Transient failure on \(request.url.path); retry \(attempt)/\(maxAttempts - 1)")
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
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }

        let request = RESTRequest(
            url: baseURL.appending(path: path),
            method: method,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            body: try encoderFactory().encode(body)
        )
        return try await perform(type, request: request)
    }

    public nonisolated func perform<T: Decodable & Sendable>(
        _ type: T.Type,
        request: RESTRequest
    ) async throws -> T {
        do {
            return try await performAttempt(type, request: request)
        } catch let failure as HTTPAttemptFailure {
            throw failure.mappedError
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

        do {
            return try await transport.response(for: request)
        } catch let overflow as RESTResponseTooLargeError {
            throw errors.decode(
                "HTTP \(overflow.statusCode) response exceeded the \(overflow.limit)-byte limit"
            )
        } catch let urlError as URLError {
            try Task.checkCancellation()
            // Surface transport failures (offline, timeout, unreachable) as a typed,
            // friendly error rather than leaking the raw URLError into the UI.
            throw errors.network(urlError)
        }
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
        keys.map(\.stringValue).joined(separator: ".")
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
        let prefix = data.prefix(maxMappedErrorBodyBytes)
        // Lossy decoding is deliberate: invalid bytes become a bounded replacement
        // scalar instead of making the mapped error body disappear.
        // swiftlint:disable:next optional_data_string_conversion
        let decoded = String(decoding: [UInt8](prefix), as: UTF8.self)
        return sanitizedText(
            decoded,
            maxScalars: maxMappedErrorBodyScalars,
            truncated: data.count > maxMappedErrorBodyBytes
        )
    }

    nonisolated static func boundedDecodeDetail(_ error: any Error) -> String {
        sanitizedText(
            "decode failed (\(type(of: error))): \(error.localizedDescription)",
            maxScalars: 512,
            truncated: false
        )
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
        ["GET", "HEAD", "OPTIONS", "TRACE", "PUT", "DELETE"].contains(method.uppercased())
    }
}

public extension PaginatedRESTClient {
    /// Builds an authenticated GET only for the configured origin. This method throws
    /// rather than placing bearer credentials on an arbitrary caller-provided URL.
    nonisolated func authorizedGET(_ url: URL) throws -> RESTRequest {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }
        guard SameOriginRedirectDelegate.hasSameOrigin(baseURL, url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil
        else {
            throw errors.http(status: 0, body: "Authenticated URL left the configured origin")
        }
        return RESTRequest(
            url: url,
            method: "GET",
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
        )
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
            throw failure.mappedError
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
    /// fully deterministic.
    func pageURL(_ page: Int?) -> URL? {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        var query = comps?.queryItems ?? []
        query.removeAll { $0.name.compare("page", options: .caseInsensitive) == .orderedSame }
        if let sort {
            query.removeAll { $0.name.compare("sort", options: .caseInsensitive) == .orderedSame }
            query.append(URLQueryItem(name: "sort", value: sort))
        }
        if let page { query.append(URLQueryItem(name: "page", value: String(page))) }
        comps?.queryItems = query.isEmpty ? nil : query
        return comps?.url
    }

    guard let firstURL = pageURL(nil) else { throw errors.http(status: 0, body: "Invalid URL") }

    let firstPage = try await performWithRetry(W.self, request: try authorizedGET(firstURL))
    var visitedPageURLs: Set<URL> = [canonicalPageURL(firstURL)]
    // `seen` de-dupes by each item's stable identity across every page, so an
    // over-requested page that echoes page 1 can't duplicate rows.
    var seen = Set<AnyHashable>()
    var items: [W.Item] = []
    Self.appendNew(firstPage.pageItems, to: &items, seen: &seen, identity: W.identity(of:))
    emit(items)

    // The parallel path speculatively requests pages by number, so a server that
    // clamps an out-of-range `page` to a page that exists can echo rows we already
    // hold. De-duplication by `identity(of:)` is what makes that safe, so a conformer
    // that returns `nil` for any item (the default implementation returns `nil` for
    // all of them) is not eligible: it takes the sequential `next_page` walk, which
    // never requests a page speculatively and so needs no de-duplication. This is the
    // contract `identity(of:)` documents.
    let canDeduplicate = firstPage.pageItems.allSatisfy { W.identity(of: $0) != nil }

    // Fast path: total + page-number URLs let us fetch pages 2…N in parallel.
    if firstPage.total != nil, !items.isEmpty, canDeduplicate {
        let tailNextPage = try await fetchKnownPages(
            W.self, firstPage: firstPage, items: &items, seen: &seen, pageURL: pageURL, emit: emit
        )
        try await walkNextPages(
            W.self,
            from: tailNextPage,
            items: &items,
            seen: &seen,
            visitedPageURLs: &visitedPageURLs,
            emit: emit
        )
        return
    }

    // Fallback: follow `next_page` one page at a time.
    try await walkNextPages(
        W.self,
        from: firstPage.nextPage,
        items: &items,
        seen: &seen,
        visitedPageURLs: &visitedPageURLs,
        emit: emit
    )
}

/// Appends only items not already seen (by their `PagedResponse` identity), updating
/// `seen`, and returns how many were actually appended. Items whose identity is `nil`
/// opt out of de-duplication and are always appended - only the sequential path, which
/// never re-requests a page, reaches this with a `nil` identity.
@discardableResult
nonisolated static func appendNew<Item>(
    _ newItems: [Item],
    to items: inout [Item],
    seen: inout Set<AnyHashable>,
    identity: (Item) -> AnyHashable?
) -> Int {
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
    firstPage: W,
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
    // The page size is the size the *client asked for* (`W.pageSize`), never the first
    // response's item count. A first page shortened by server-side filtering would make
    // the divisor too small and so over-estimate the page count, sending the client
    // after pages that do not exist - and one 404 on an out-of-range page fails the
    // whole task group, discarding every record already fetched. Erring the other way
    // is harmless: a short page count just leaves a remainder for the `next_page` walk.
    let pageSize = W.pageSize
    guard pageSize > 0 else { throw errors.decode("page size must be positive, got \(pageSize)") }

    let total = firstPage.total ?? items.count
    // `total` is decoded straight from JSON, so validate it before it reaches the
    // page-count arithmetic: `total + pageSize - 1` on `Int.max` traps the process.
    guard total >= 0, total <= Self.maxReportedTotal else { throw errors.decode("total out of range: \(total)") }

    let pageCount = max(1, (total / pageSize) + (total % pageSize == 0 ? 0 : 1))
    // Mirrors `maxSequentialPages`: bound the requests one list can issue, since
    // `pageCount` is derived from a server-supplied number. Surface the cap as an
    // error rather than silently truncating, exactly as the sequential walk does.
    guard pageCount <= Self.maxParallelPages else {
        throw errors.http(status: 0,
                          body: "Pagination exceeded \(Self.maxParallelPages) parallel pages")
    }
    guard pageCount > 1 else { return firstPage.nextPage }

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
            guard let url = pageURL(page) else { throw errors.http(status: 0, body: "Invalid URL") }

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
                    ready.pageItems, to: &collected, seen: &seen, identity: W.identity(of:)
                )
                // The final page's `next_page` tells us whether the estimate fell
                // short. A duplicate-only page can still be genuinely in range after
                // concurrent insert/delete drift, so do not require it to add rows.
                // Reject only links that point back into the already fetched numbered
                // range, which is how an out-of-range request clamped to page one shows
                // up here.
                if nextToEmit == pageCount {
                    tailNextPage = try advancingTailNextPage(
                        ready.nextPage,
                        afterEstimatedPage: pageCount
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
    afterEstimatedPage pageCount: Int
) throws -> String? {
    guard let value, let url = try validatedNextPageURL(value) else { return nil }
    let pageValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name.compare("page", options: .caseInsensitive) == .orderedSame }?
        .value
    if let pageValue, let page = Int(pageValue), page <= pageCount { return nil }
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
    items: inout [W.Item],
    seen: inout Set<AnyHashable>,
    visitedPageURLs: inout Set<URL>,
    emit: ([W.Item]) -> Void
) async throws {
    var url = try start.flatMap { try validatedNextPageURL($0) }
    var pages = 0
    while let current = url {
        guard visitedPageURLs.insert(canonicalPageURL(current)).inserted else {
            throw errors.http(status: 0, body: "Pagination next_page cycle detected")
        }

        let page = try await performWithRetry(W.self, request: try authorizedGET(current))
        Self.appendNew(page.pageItems, to: &items, seen: &seen, identity: W.identity(of:))
        emit(items)
        pages += 1
        guard let next = page.nextPage,
              let nextURL = try validatedNextPageURL(next)
        else { break }

        // Safety valve against a server that keeps handing back next_page links.
        // Surface the cap as an error rather than silently truncating the list -
        // a caller swallowing data without any signal is worse than a failure.
        guard pages < Self.maxSequentialPages else {
            throw errors.http(status: 0,
                              body: "Pagination exceeded \(Self.maxSequentialPages) sequential pages")
        }

        url = nextURL
    }
}

/// Resolves a response-provided pagination link without granting it authority to choose
/// where the bearer credential is sent. Relative links are supported, while every
/// absolute result must remain on the configured HTTP(S) origin.
nonisolated func validatedNextPageURL(_ value: String) throws -> URL? {
    guard !value.isEmpty else { return nil }
    guard let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
        throw errors.http(status: 0, body: "Invalid pagination next_page")
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
        throw errors.http(status: 0, body: "Pagination next_page left the configured origin")
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
