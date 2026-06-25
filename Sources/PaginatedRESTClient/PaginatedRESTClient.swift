//
//  PaginatedRESTClient.swift
//  PaginatedRESTClient
//
//  A generic, domain-free transport for paginated, bearer-authenticated REST APIs:
//  request building, retry with exponential backoff, concurrent multi-page fetching,
//  and background JSON decoding. The transport concern is reusable and unit-testable
//  apart from any domain-specific models and endpoints, which compose it.
//
//  The decoder, request-body encoder, error mapping, and logger are all injected, so
//  nothing here knows any particular API's date quirks, model shapes, error type, or
//  logging subsystem. The transport builds its failures through an injected
//  `RESTTransportErrorMapping` rather than naming a domain error, so it carries no
//  coupling to any one API.
//

import Foundation
import os

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
    /// A stable identity used to de-duplicate items when stitching parallel pages,
    /// so a server that echoes page 1 for an over-requested `page` can't produce
    /// duplicate rows. `nil` opts out (e.g. items with no stable unique id, which
    /// take the sequential path anyway).
    nonisolated static func identity(of item: Item) -> AnyHashable?
}

public extension PagedResponse {
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

// MARK: - Client

/// The reusable transport. Carries only immutable, Sendable configuration and drives
/// pure networking, so its stored properties and the low-level request/pagination
/// methods are `nonisolated`: it lets the pagination pipeline run off the main actor
/// (see `streamAllPages`) rather than being pinned to it by the module's default
/// MainActor isolation.
public struct PaginatedRESTClient {
    nonisolated let apiKey: String
    nonisolated let baseURL: URL
    nonisolated let session: URLSession
    /// Builds a configured decoder per call. A factory rather than a shared instance
    /// because decoding runs off the main actor (see `perform`) and `JSONDecoder`
    /// isn't safe to share across threads — each background decode gets its own.
    nonisolated let decoderFactory: @Sendable () -> JSONDecoder
    /// Supplies the encoder for request bodies. A closure (not a stored `JSONEncoder`)
    /// so the transport stays `Sendable` — its `nonisolated` pagination methods capture
    /// `self` in child tasks, and `JSONEncoder` isn't `Sendable`. The composing client
    /// owns the body shapes and date strategy, so the encoder is a domain concern.
    nonisolated let encoderFactory: @Sendable () -> JSONEncoder
    /// Builds the transport's failures as the composing client's error type, so this file
    /// names no domain error (see `RESTTransportErrorMapping`).
    nonisolated let errors: any RESTTransportErrorMapping
    /// Where retry diagnostics go. Injected so the package owns no logging subsystem;
    /// `Logger` is `Sendable`, so it travels into the nonisolated pagination methods.
    nonisolated let logger: Logger

    /// Upper bound on `next_page` follows for one list, guarding against a server
    /// that keeps handing back links. Hitting it throws rather than truncating.
    nonisolated static let maxSequentialPages = 1000

    public init(
        apiKey: String,
        baseURL: URL,
        session: URLSession,
        decoderFactory: @escaping @Sendable () -> JSONDecoder,
        encoderFactory: @escaping @Sendable () -> JSONEncoder,
        errors: any RESTTransportErrorMapping,
        logger: Logger
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.decoderFactory = decoderFactory
        self.encoderFactory = encoderFactory
        self.errors = errors
        self.logger = logger
    }

    public nonisolated func authorizedGET(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func fetch<T: Decodable & Sendable>(_ type: T.Type, path: String) async throws -> T {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }

        return try await performWithRetry(type, request: authorizedGET(baseURL.appending(path: path)))
    }

    /// Accumulates every page of a paginated list endpoint. Convenience over
    /// `streamAllPages` for callers that only want the final, complete list.
    public func fetchAllPages<W: PagedResponse>(
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

    /// Streams cumulative snapshots of a paginated list endpoint, yielding page 1 first so
    /// callers can render before the whole list is in.
    ///
    /// When the first response reports a `total`, the page count is known up front and the
    /// remaining pages (numbered `?page=2…N`) are fetched concurrently — turning what was a
    /// serial chain of round-trips into a few parallel waves. On a large list this is the
    /// difference between tens of seconds and a few. Completed pages are emitted as a
    /// growing contiguous prefix, so each snapshot is correctly ordered even though pages
    /// finish out of order. Endpoints that omit `total` (or any future cursor-style
    /// pagination) fall back to walking `next_page` sequentially, emitting a snapshot per
    /// page. Without this whole mechanism, callers would silently receive only the first page.
    public func streamAllPages<W: PagedResponse>(
        _: W.Type,
        path: String,
        sort: String? = nil
    ) -> AsyncThrowingStream<[W.Item], Error> {
        AsyncThrowingStream { continuation in
            // This method and the networking it calls are `nonisolated`, so this
            // unstructured `Task` does not inherit the module's default main-actor
            // isolation — the pipeline, including the concurrent child tasks below,
            // runs on the cooperative pool. That keeps the list-building work (URL
            // construction, snapshot accumulation) off the main thread while pages
            // stream in. (Inheriting the main actor is exactly what a plain `Task`
            // would do from a MainActor-isolated context, regardless of Sendability.)
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

    /// Drives the page-by-page fetch, calling `emit` with each cumulative snapshot.
    /// Splits into the parallel "fast path" (when `total` is known) and the
    /// sequential `next_page` walk, both extracted into helpers below.
    private nonisolated func drivePagination<W: PagedResponse>(
        _: W.Type,
        path: String,
        sort: String?,
        emit: ([W.Item]) -> Void
    ) async throws {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }

        let baseQuery: [URLQueryItem] = sort.map { [URLQueryItem(name: "sort", value: $0)] } ?? []

        /// Builds `…/path?sort=…&page=N`. Page numbers are constructed here
        /// rather than taken from `next_page` so the parallel fetch is
        /// fully deterministic.
        func pageURL(_ page: Int?) -> URL? {
            var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
            var query = baseQuery
            if let page { query.append(URLQueryItem(name: "page", value: String(page))) }
            comps?.queryItems = query.isEmpty ? nil : query
            return comps?.url
        }

        guard let firstURL = pageURL(nil) else { throw errors.http(status: 0, body: "Invalid URL") }

        let firstPage = try await performWithRetry(W.self, request: authorizedGET(firstURL))
        // `seen` de-dupes by each item's stable identity across every page, so an
        // over-requested page that echoes page 1 can't duplicate rows.
        var seen = Set<AnyHashable>()
        var items: [W.Item] = []
        Self.appendNew(firstPage.pageItems, to: &items, seen: &seen, identity: W.identity(of:))
        emit(items)

        // Fast path: total + page-number URLs let us fetch pages 2…N in parallel.
        if firstPage.total != nil, !items.isEmpty {
            let tailNextPage = try await fetchKnownPages(
                W.self, firstPage: firstPage, items: &items, seen: &seen, pageURL: pageURL, emit: emit
            )
            try await walkNextPages(W.self, from: tailNextPage, items: &items, seen: &seen, emit: emit)
            return
        }

        // Fallback: follow `next_page` one page at a time.
        try await walkNextPages(W.self, from: firstPage.nextPage, items: &items, seen: &seen, emit: emit)
    }

    /// Appends only items not already seen (by their `PagedResponse` identity),
    /// updating `seen`. Items whose identity is `nil` opt out of de-duplication and
    /// are always appended.
    private nonisolated static func appendNew<Item>(
        _ newItems: [Item],
        to items: inout [Item],
        seen: inout Set<AnyHashable>,
        identity: (Item) -> AnyHashable?
    ) {
        for item in newItems {
            guard let key = identity(item) else { items.append(item); continue }

            if seen.insert(key).inserted { items.append(item) }
        }
    }

    /// Fetches pages 2…N concurrently (bounded window), appending each completed page in
    /// contiguous order and emitting a snapshot whenever the ordered prefix grows. Returns
    /// the `next_page` of the final estimated page, so the caller can pick up any remainder.
    private nonisolated func fetchKnownPages<W: PagedResponse>(
        _: W.Type,
        firstPage: W,
        items: inout [W.Item],
        seen: inout Set<AnyHashable>,
        pageURL: (Int?) -> URL?,
        emit: ([W.Item]) -> Void
    ) async throws -> String? {
        // `total` is a lower bound on the page count: it can undercount if records are
        // created mid-load, and the first page can be short. So fetch pages 2…N in
        // parallel, then follow `next_page` from the final page to pick up any remainder
        // rather than silently dropping records past the estimate.
        let pageSize = items.count
        let total = firstPage.total ?? pageSize
        let pageCount = max(1, (total + pageSize - 1) / pageSize)
        guard pageCount > 1 else { return firstPage.nextPage }

        var tailNextPage: String? = firstPage.nextPage
        var pending: [Int: W] = [:]
        var nextToEmit = 2
        var collected = items
        try await withThrowingTaskGroup(of: (Int, W).self) { group in
            func enqueue(_ page: Int) throws {
                guard let url = pageURL(page) else { throw errors.http(status: 0, body: "Invalid URL") }

                group.addTask {
                    try await (page, performWithRetry(W.self, request: authorizedGET(url)))
                }
            }
            // Keep a bounded window in flight — enough to saturate the network without
            // unleashing dozens of connections (which invite 429s).
            let maxConcurrent = 8
            var nextToFetch = 2
            while nextToFetch <= pageCount, nextToFetch - 2 < maxConcurrent {
                try enqueue(nextToFetch); nextToFetch += 1
            }
            while let (page, response) = try await group.next() {
                pending[page] = response
                // The final page's `next_page` tells us whether the estimate fell short.
                if page == pageCount { tailNextPage = response.nextPage }
                // Emit a new snapshot whenever the contiguous prefix grows.
                var grew = false
                while let ready = pending.removeValue(forKey: nextToEmit) {
                    Self.appendNew(ready.pageItems, to: &collected, seen: &seen, identity: W.identity(of:))
                    nextToEmit += 1; grew = true
                }
                if grew { emit(collected) }
                if nextToFetch <= pageCount { try enqueue(nextToFetch); nextToFetch += 1 }
            }
        }
        items = collected
        return tailNextPage
    }

    /// Walks `next_page` links one page at a time, appending and emitting each page.
    /// Used for the fallback path and to pick up any remainder past a parallel estimate.
    private nonisolated func walkNextPages<W: PagedResponse>(
        _: W.Type,
        from start: String?,
        items: inout [W.Item],
        seen: inout Set<AnyHashable>,
        emit: ([W.Item]) -> Void
    ) async throws {
        var url = start.flatMap { URL(string: $0) }
        var pages = 0
        while let current = url {
            let page = try await performWithRetry(W.self, request: authorizedGET(current))
            Self.appendNew(page.pageItems, to: &items, seen: &seen, identity: W.identity(of:))
            emit(items)
            pages += 1
            guard let next = page.nextPage, let nextURL = URL(string: next) else { break }

            // Safety valve against a server that keeps handing back next_page links.
            // Surface the cap as an error rather than silently truncating the list —
            // a caller swallowing data without any signal is worse than a failure.
            guard pages < Self.maxSequentialPages else {
                throw errors.http(status: 0,
                                  body: "Pagination exceeded \(Self.maxSequentialPages) sequential pages")
            }

            url = nextURL
        }
    }

    /// GET requests are idempotent, so transient failures (5xx, 429, network timeouts)
    /// are retried with exponential backoff before the error surfaces to the UI. Mutating
    /// requests go straight through `perform` to avoid duplicating side effects.
    public nonisolated func performWithRetry<T: Decodable & Sendable>(
        _ type: T.Type,
        request: URLRequest,
        maxAttempts: Int = 3
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await perform(type, request: request)
            } catch {
                attempt += 1
                guard attempt < maxAttempts, errors.isTransient(error) else { throw error }

                logger.debug(
                    """
                    Transient failure on \(request.url?.path ?? "", privacy: .public); \
                    retry \(attempt)/\(maxAttempts - 1)
                    """
                )
                // 300ms, then 600ms. Let cancellation propagate so a torn-down
                // stream stops here rather than issuing another request.
                try await Task.sleep(for: .milliseconds(300 * (1 << (attempt - 1))))
            }
        }
    }

    public func send<T: Decodable & Sendable>(
        _ type: T.Type,
        method: String,
        path: String,
        body: some Encodable
    ) async throws -> T {
        guard !apiKey.isEmpty else { throw errors.missingAPIKey() }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoderFactory().encode(body)
        return try await perform(type, request: request)
    }

    public func perform<T: Decodable & Sendable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            // Surface transport failures (offline, timeout, unreachable) as a typed,
            // friendly error rather than leaking the raw URLError into the UI.
            throw errors.network(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw errors.http(status: 0, body: "No HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw errors.http(status: http.statusCode, body: body)
        }

        do {
            // Decode off the main actor: the client may be MainActor-isolated, so on a large
            // list (many pages × nested objects) decoding here would hitch the UI.
            // `Data` and `T` are Sendable, so the work crosses the boundary cleanly.
            return try await decodeInBackground(T.self, from: data)
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
        }
    }

    private nonisolated func pathString(_ keys: [CodingKey]) -> String {
        keys.map(\.stringValue).joined(separator: ".")
    }

    /// Decodes `data` on a background task so the (potentially large) parse doesn't run on
    /// the main actor. Builds a fresh decoder per call — `JSONDecoder` isn't safe to share
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
