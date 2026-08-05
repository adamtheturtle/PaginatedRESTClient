import Foundation
@testable import PaginatedRESTClient
import Testing

// MARK: - Test doubles

/// A minimal error mapping: the paginator names no domain error, so the tests supply a
/// trivial one and treat HTTP 5xx/429 and `URLError`s as transient.
private struct TestErrors: RESTTransportErrorMapping {
    enum Failure: Error, Equatable {
        case missingAPIKey
        case http(Int)
        case decode
        case network
    }

    nonisolated func missingAPIKey() -> Error {
        Failure.missingAPIKey
    }

    nonisolated func http(status: Int, body _: String) -> Error {
        Failure.http(status)
    }

    nonisolated func decode(_: String) -> Error {
        Failure.decode
    }

    nonisolated func network(_: URLError) -> Error {
        Failure.network
    }

    nonisolated func isTransient(_ error: Error) -> Bool {
        if case let .http(code) = error as? Failure {
            return (500 ... 599).contains(code) || code == 429 || code == 0
        }
        return (error as? Failure) == .network
    }
}

private enum DetailedFailure: Error, Equatable {
    case http(Int, String)
    case decode(String)
    case unexpected
}

private struct DetailedErrors: RESTTransportErrorMapping {
    nonisolated func missingAPIKey() -> any Error { DetailedFailure.unexpected }
    nonisolated func http(status: Int, body: String) -> any Error { DetailedFailure.http(status, body) }
    nonisolated func decode(_ detail: String) -> any Error { DetailedFailure.decode(detail) }
    nonisolated func network(_: URLError) -> any Error { DetailedFailure.unexpected }
    nonisolated func isTransient(_: any Error) -> Bool { false }
}

private nonisolated struct RejectingValue: Decodable, Sendable {
    struct ValidationError: LocalizedError {
        var errorDescription: String? { "domain validation rejected the value" }
    }

    init(from _: any Decoder) throws {
        throw ValidationError()
    }
}

private nonisolated struct Thing: Decodable, Equatable {
    let id: Int
}

/// A two-page list response: page 1 reports `total`, so the client computes the page
/// count and fetches page 2 in parallel. `nonisolated` so its `pageItems`/`Decodable`
/// satisfy `PagedResponse`'s nonisolated requirements under the module's MainActor
/// default isolation.
private nonisolated struct ThingsPage: PagedResponse {
    let things: [Thing]
    let nextPage: String?
    let total: Int?
    var pageItems: [Thing] {
        things
    }

    nonisolated static var pageSize: Int {
        2
    }

    nonisolated static func identity(of item: Thing) -> AnyHashable? {
        item.id
    }

    enum CodingKeys: String, CodingKey { case things; case nextPage = "next_page"; case total }
}

/// Same shape as `ThingsPage`, but declaring the ten-item page size the scripted servers
/// below serve. Used by the page-count regression tests.
private nonisolated struct TenPerPage: PagedResponse {
    let things: [Thing]
    let nextPage: String?
    let total: Int?
    var pageItems: [Thing] {
        things
    }

    nonisolated static var pageSize: Int {
        10
    }

    nonisolated static func identity(of item: Thing) -> AnyHashable? {
        item.id
    }

    enum CodingKeys: String, CodingKey { case things; case nextPage = "next_page"; case total }
}

private nonisolated struct HugePageSize: PagedResponse {
    let things: [Thing]
    let nextPage: String?
    let total: Int?
    var pageItems: [Thing] { things }

    nonisolated static var pageSize: Int { .max }
    nonisolated static func identity(of item: Thing) -> AnyHashable? { item.id }

    enum CodingKeys: String, CodingKey { case things; case nextPage = "next_page"; case total }
}

/// Supplies identities on page one but deliberately withholds one on page two, which
/// must invalidate the speculative parallel path before that page is emitted.
private nonisolated struct PartialIdentityPage: PagedResponse {
    let things: [Thing]
    let nextPage: String?
    let total: Int?
    var pageItems: [Thing] { things }

    nonisolated static var pageSize: Int { 10 }

    nonisolated static func identity(of item: Thing) -> AnyHashable? {
        item.id == 11 ? nil : item.id
    }

    enum CodingKeys: String, CodingKey { case things; case nextPage = "next_page"; case total }
}

/// A conformer that does not implement `identity(of:)`, so it inherits the default `nil`
/// identity. It declares a page size purely so that, were the parallel path taken, it
/// would be taken with de-duplication disabled - which is the bug under test.
private nonisolated struct Unidentified: PagedResponse {
    let things: [Thing]
    let nextPage: String?
    let total: Int?
    var pageItems: [Thing] {
        things
    }

    nonisolated static var pageSize: Int {
        10
    }

    enum CodingKeys: String, CodingKey { case things; case nextPage = "next_page"; case total }
}

/// `Thread.isMainThread` is unavailable directly inside an async body, so ask through a
/// synchronous function. Whether the transport runs on the main thread is exactly what the
/// isolation regression test needs to observe.
private nonisolated func isOnMainThread() -> Bool {
    Thread.isMainThread
}

/// Records what a scripted server was asked for, across the concurrent page fetches.
private nonisolated final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Int] = []
    private var mainThreadCalls = 0

    func record(page: Int, onMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }

        pages.append(page)
        if onMainThread { mainThreadCalls += 1 }
    }

    var requestedPages: [Int] {
        lock.withLock { pages }
    }

    var mainThreadRequestCount: Int {
        lock.withLock { mainThreadCalls }
    }
}

/// Serves a list defined by `pages` (page 1 first) and a policy for pages past the end,
/// so each regression test can describe the server behaviour it needs.
private nonisolated struct ScriptedTransport: RESTTransport {
    /// How the server treats a `page` beyond the last real page.
    enum OutOfRange: Sendable {
        /// 404 - not classified as transient, so it fails the whole load.
        case notFound
        /// Clamp to page 1, the common behaviour that lets a stale `next_page` re-walk.
        case clampToFirstPage
    }

    let pages: [[Int]]
    let total: Int
    let outOfRange: OutOfRange
    let log: RequestLog

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value
        let page = query.flatMap(Int.init) ?? 1
        log.record(page: page, onMainThread: isOnMainThread())

        guard page <= pages.count else {
            switch outOfRange {
            case .notFound:
                return (Data("not found".utf8), 404)
            case .clampToFirstPage:
                return (Data(pageJSON(1).utf8), 200)
            }
        }

        return (Data(pageJSON(page).utf8), 200)
    }

    private func pageJSON(_ page: Int) -> String {
        let things = pages[page - 1].map { #"{"id":\#($0)}"# }.joined(separator: ",")
        let next = page < pages.count ? #""https://example.test/things/?page=\#(page + 1)""# : "null"
        return #"{"things":[\#(things)],"next_page":\#(next),"total":\#(total)}"#
    }
}

/// Serves a single first page verbatim, for the `total`-validation tests.
private nonisolated struct FixedFirstPageTransport: RESTTransport {
    let json: String

    func data(for _: RESTRequest) async throws -> (Data, Int) {
        (Data(json.utf8), 200)
    }
}

private nonisolated final class CapturedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RESTRequest] = []

    func append(_ request: RESTRequest) -> Int {
        lock.withLock {
            requests.append(request)
            return requests.count
        }
    }

    var values: [RESTRequest] {
        lock.withLock { requests }
    }
}

private nonisolated struct NextPageTransport: RESTTransport {
    let nextPage: String
    let laterNextPage: String?
    let captured: CapturedRequests

    init(nextPage: String, laterNextPage: String? = nil, captured: CapturedRequests) {
        self.nextPage = nextPage
        self.laterNextPage = laterNextPage
        self.captured = captured
    }

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        let requestNumber = captured.append(request)
        let next: Any = switch requestNumber {
        case 1: nextPage
        case 2: laterNextPage ?? NSNull()
        default: NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "things": [["id": requestNumber]],
            "next_page": next,
            "total": NSNull()
        ])
        return (data, 200)
    }
}

private nonisolated struct CycleTransport: RESTTransport {
    enum Kind: Sendable {
        case selfLoop
        case twoPages
    }

    let kind: Kind
    let captured: CapturedRequests

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        _ = captured.append(request)
        let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value
        let id = page == "2" ? 2 : 1
        let nextPage = switch (kind, page) {
        case (.selfLoop, _), (.twoPages, "2"):
            "https://EXAMPLE.test:443/things/#fragment"
        case (.twoPages, _):
            "/things/?page=2"
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "things": [["id": id]],
            "next_page": nextPage,
            "total": NSNull()
        ])
        return (data, 200)
    }
}

/// Serves a fixed two-page fixture keyed off the `page` query item, with no real
/// networking - a `RESTTransport` stub in place of the old `URLProtocol`/`URLSession`
/// machinery, so the tests exercise the paginator over the same seam consumers use and
/// stay Foundation-only (Linux-clean).
private struct StubTransport: RESTTransport {
    func data(for request: RESTRequest) async throws -> (Data, Int) {
        let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value
        let json = switch page {
        case nil, "1":
            #"{"things":[{"id":1},{"id":2}],"next_page":"https://example.test/things/?page=2","total":3}"#
        case "2":
            #"{"things":[{"id":3}],"next_page":null,"total":3}"#
        default:
            #"{"things":[],"next_page":null,"total":3}"#
        }
        return (Data(json.utf8), 200)
    }
}

private nonisolated struct QueryCaptureTransport: RESTTransport {
    let captured: CapturedRequests

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        _ = captured.append(request)
        return try await StubTransport().data(for: request)
    }
}

private nonisolated struct FixedResponseTransport: RESTTransport {
    let data: Data
    let status: Int

    func data(for _: RESTRequest) async throws -> (Data, Int) {
        (data, status)
    }
}

/// A wall clock that tests can advance without waiting in real time.
private nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 0)) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date.addTimeInterval(interval) }
    }
}

/// Suspends every caller until the test advances the shared clock and releases them.
private nonisolated final class ControlledSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    func sleep(for delay: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                delays.append(delay)
                continuations.append(continuation)
            }
        }
    }

    var requestedDelays: [TimeInterval] {
        lock.withLock { delays }
    }

    func resumeAll() {
        let waiting = lock.withLock {
            let result = continuations
            continuations.removeAll()
            return result
        }
        waiting.forEach { $0.resume() }
    }
}

/// Returns one rate limit response followed by a success, retaining mixed-case headers
/// to exercise the header-aware transport path and case-insensitive lookup together.
private nonisolated final class RetryOnceTransport: RESTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    let retryAfter: String?

    init(retryAfter: String?) {
        self.retryAfter = retryAfter
    }

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        let response = try await response(for: request)
        return (response.data, response.statusCode)
    }

    func response(for _: RESTRequest) async throws -> RESTResponse {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            return RESTResponse(
                data: Data("limited".utf8),
                statusCode: 429,
                headers: retryAfter.map { ["rEtRy-AfTeR": $0] } ?? [:]
            )
        }
        return RESTResponse(data: Data(#"{"id":1}"#.utf8), statusCode: 200)
    }

    var requestCount: Int {
        lock.withLock { attempts }
    }
}

private nonisolated final class CountingStatusTransport: RESTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    let status: Int

    init(status: Int) {
        self.status = status
    }

    func data(for _: RESTRequest) async throws -> (Data, Int) {
        lock.withLock { attempts += 1 }
        let body = status == 200 ? #"{"id":1}"# : "failure"
        return (Data(body.utf8), status)
    }

    var requestCount: Int { lock.withLock { attempts } }
}

private nonisolated final class TerminalRateLimitTransport: RESTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func response(for request: RESTRequest) async throws -> RESTResponse {
        lock.withLock { paths.append(request.url.path) }
        if request.url.path == "/limited" {
            return RESTResponse(
                data: Data("limited".utf8),
                statusCode: 429,
                headers: ["Retry-After": "600"]
            )
        }
        return RESTResponse(data: Data(#"{"id":1}"#.utf8), statusCode: 200)
    }

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        let response = try await response(for: request)
        return (response.data, response.statusCode)
    }

    func requestCount(path: String) -> Int {
        lock.withLock { paths.count(where: { $0 == path }) }
    }
}

/// Makes pages 2 and 3 reach their first 429 together, then serves both successfully.
/// The barrier prevents scheduler order from weakening the shared-cooldown assertion.
private nonisolated final class ConcurrentRateLimitTransport: RESTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [Int: Int] = [:]
    private var rateLimited: [CheckedContinuation<RESTResponse, Never>] = []

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        let response = try await response(for: request)
        return (response.data, response.statusCode)
    }

    func response(for request: RESTRequest) async throws -> RESTResponse {
        let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
        let attempt = lock.withLock {
            attempts[page, default: 0] += 1
            return attempts[page]!
        }

        if page > 1, attempt == 1 {
            return await withCheckedContinuation { continuation in
                let waiting = lock.withLock {
                    rateLimited.append(continuation)
                    guard rateLimited.count == 2 else { return [CheckedContinuation<RESTResponse, Never>]() }
                    let result = rateLimited
                    rateLimited.removeAll()
                    return result
                }
                let response = RESTResponse(
                    data: Data("limited".utf8),
                    statusCode: 429,
                    headers: ["Retry-After": "10"]
                )
                waiting.forEach { $0.resume(returning: response) }
            }
        }

        let ids = switch page {
        case 1: [1, 2]
        case 2: [3, 4]
        default: [5, 6]
        }
        let things = ids.map { #"{"id":\#($0)}"# }.joined(separator: ",")
        let next = page < 3 ? #""https://example.test/things/?page=\#(page + 1)""# : "null"
        let json = #"{"things":[\#(things)],"next_page":\#(next),"total":6}"#
        return RESTResponse(data: Data(json.utf8), statusCode: 200)
    }

    func requestCount(for page: Int) -> Int {
        lock.withLock { attempts[page, default: 0] }
    }
}

private func makeClient(
    transport: any RESTTransport = StubTransport(),
    baseURL: URL = URL(string: "https://example.test")!,
    retryRuntime: RetryRuntime = .live
) -> PaginatedRESTClient {
    PaginatedRESTClient(
        apiKey: "test-key",
        baseURL: baseURL,
        transport: transport,
        decoderFactory: { JSONDecoder() },
        encoderFactory: { JSONEncoder() },
        errors: TestErrors(),
        retryRuntime: retryRuntime
    )
}

// MARK: - Tests

@Suite("PaginatedRESTClient")
struct PaginatedRESTClientTests {
    @Test
    func `custom decoding failures use the configured mapping`() async throws {
        let client = PaginatedRESTClient(
            apiKey: "test-key",
            baseURL: try #require(URL(string: "https://example.test")),
            transport: FixedResponseTransport(data: Data("{}".utf8), status: 200),
            decoderFactory: { JSONDecoder() },
            encoderFactory: { JSONEncoder() },
            errors: DetailedErrors()
        )

        let error = await #expect(throws: DetailedFailure.self) {
            _ = try await client.fetch(RejectingValue.self, path: "/value")
        }
        guard case let .decode(detail) = error else {
            Issue.record("Expected a mapped decode failure")
            return
        }
        #expect(detail.contains("domain validation rejected the value"))
    }

    @Test
    func `mapped HTTP bodies are bounded sanitized and marked when truncated`() async throws {
        let body = Data([0, 0xFF]) + Data(repeating: 97, count: 20_000)
        let client = PaginatedRESTClient(
            apiKey: "test-key",
            baseURL: try #require(URL(string: "https://example.test")),
            transport: FixedResponseTransport(data: body, status: 500),
            decoderFactory: { JSONDecoder() },
            encoderFactory: { JSONEncoder() },
            errors: DetailedErrors()
        )

        let error = await #expect(throws: DetailedFailure.self) {
            _ = try await client.fetch(Thing.self, path: "/value")
        }
        guard case let .http(status, mappedBody) = error else {
            Issue.record("Expected a mapped HTTP failure")
            return
        }
        #expect(status == 500)
        #expect(mappedBody.hasSuffix(" [truncated]"))
        #expect(mappedBody.unicodeScalars.count <= 1_037)
        #expect(!mappedBody.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }))
    }

    @Test
    func `case-variant duplicate response headers use deterministic precedence`() {
        var response = RESTResponse(
            data: Data(),
            statusCode: 429,
            headers: ["retry-after": "20", "Retry-After": "10"]
        )

        #expect(response.headers == ["retry-after": "10"])
        #expect(response.value(forHTTPHeaderField: "RETRY-AFTER") == "10")

        response.headers["Retry-After"] = "30"
        #expect(response.value(forHTTPHeaderField: "retry-after") == "30")
    }

    @Test
    func `fetchAllPages stitches every page in order`() async throws {
        let items = try await makeClient().fetchAllPages(ThingsPage.self, path: "/things/")
        #expect(items == [Thing(id: 1), Thing(id: 2), Thing(id: 3)])
    }

    @Test
    func `streamAllPages emits a growing prefix, page one first`() async throws {
        var snapshots: [[Thing]] = []
        for try await snapshot in makeClient().streamAllPages(ThingsPage.self, path: "/things/") {
            snapshots.append(snapshot)
        }
        // First snapshot is page 1 alone; the last is the complete, ordered list.
        #expect(snapshots.first == [Thing(id: 1), Thing(id: 2)])
        #expect(snapshots.last == [Thing(id: 1), Thing(id: 2), Thing(id: 3)])
    }

    @Test
    func `a slow stream consumer retains only the newest cumulative snapshot`() async throws {
        let pages = stride(from: 1, through: 1_000, by: 10).map { Array($0 ... ($0 + 9)) }
        let log = RequestLog()
        let stream = makeClient(transport: ScriptedTransport(
            pages: pages,
            total: 1_000,
            outOfRange: .notFound,
            log: log
        )).streamAllPages(TenPerPage.self, path: "/things/")

        while log.requestedPages.count < 100 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        var snapshots: [[Thing]] = []
        for try await snapshot in stream { snapshots.append(snapshot) }

        #expect(snapshots == [things(1 ... 1_000)])
    }

    @Test
    func `base URL query items survive first and numbered page construction`() async throws {
        let captured = CapturedRequests()
        let baseURL = try #require(URL(string:
            "https://example.test/api?tenant=acme&version=2&page=99&sort=old"
        ))

        _ = try await makeClient(
            transport: QueryCaptureTransport(captured: captured),
            baseURL: baseURL
        ).fetchAllPages(ThingsPage.self, path: "/things/", sort: "new")

        #expect(captured.values.count == 2)
        for request in captured.values {
            let query = try #require(URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )?.queryItems)
            #expect(query.filter { $0.name == "tenant" }.map(\.value) == ["acme"])
            #expect(query.filter { $0.name == "version" }.map(\.value) == ["2"])
            #expect(query.filter { $0.name == "sort" }.map(\.value) == ["new"])
        }
        #expect(captured.values.first?.url.query?.contains("page=") == false)
        #expect(captured.values.last?.url.query?.contains("page=2") == true)
    }

    @Test
    func `an empty API key fails before any request`() async throws {
        let client = PaginatedRESTClient(
            apiKey: "",
            baseURL: try #require(URL(string: "https://example.test")),
            transport: StubTransport(),
            decoderFactory: { JSONDecoder() },
            encoderFactory: { JSONEncoder() },
            errors: TestErrors()
        )
        await #expect(throws: TestErrors.Failure.missingAPIKey) {
            _ = try await client.fetch(Thing.self, path: "/things/1")
        }
    }

    @Test
    func `the paginator authorizes requests with a bearer token`() async throws {
        let request = makeClient().authorizedGET(try #require(URL(string: "https://example.test/things/")))
        #expect(request.method == "GET")
        #expect(request.headers["Authorization"] == "Bearer test-key")
        #expect(request.headers["Accept"] == "application/json")
    }

    @Test(arguments: [
        "https://attacker.test/things/?page=2",
        "http://example.test/things/?page=2",
        "https://example.test:444/things/?page=2",
        "https://user:password@example.test/things/?page=2"
    ])
    func `next page cannot move bearer credentials off the configured origin`(
        nextPage: String
    ) async throws {
        let captured = CapturedRequests()
        let client = makeClient(transport: NextPageTransport(nextPage: nextPage, captured: captured))

        await #expect(throws: TestErrors.Failure.http(0)) {
            _ = try await client.fetchAllPages(Unidentified.self, path: "/things/")
        }

        #expect(captured.values.count == 1)
        #expect(captured.values.first?.headers["Authorization"] == "Bearer test-key")
    }

    @Test(arguments: [
        "?page=2",
        "/things/?page=2",
        "https://EXAMPLE.test:443/things/?page=2"
    ])
    func `same-origin relative and absolute next pages remain authorized`(
        nextPage: String
    ) async throws {
        let captured = CapturedRequests()
        let client = makeClient(transport: NextPageTransport(nextPage: nextPage, captured: captured))

        let items = try await client.fetchAllPages(Unidentified.self, path: "/things/")

        #expect(items == [Thing(id: 1), Thing(id: 2)])
        #expect(captured.values.count == 2)
        #expect(captured.values.last?.headers["Authorization"] == "Bearer test-key")
    }

    @Test
    func `an empty next page terminates the walk without an error`() async throws {
        let captured = CapturedRequests()
        let client = makeClient(transport: NextPageTransport(nextPage: "", captured: captured))

        let items = try await client.fetchAllPages(Unidentified.self, path: "/things/")

        #expect(items == [Thing(id: 1)])
        #expect(captured.values.count == 1)
    }

    @Test(arguments: ["http://[::1", "https://"])
    func `an invalid initial next page fails instead of truncating`(nextPage: String) async throws {
        let captured = CapturedRequests()
        let client = makeClient(transport: NextPageTransport(nextPage: nextPage, captured: captured))

        await #expect(throws: TestErrors.Failure.http(0)) {
            _ = try await client.fetchAllPages(Unidentified.self, path: "/things/")
        }

        #expect(captured.values.count == 1)
    }

    @Test
    func `an invalid later next page fails instead of returning a prefix`() async throws {
        let captured = CapturedRequests()
        let transport = NextPageTransport(
            nextPage: "?page=2",
            laterNextPage: "http://[::1",
            captured: captured
        )

        await #expect(throws: TestErrors.Failure.http(0)) {
            _ = try await makeClient(transport: transport)
                .fetchAllPages(Unidentified.self, path: "/things/")
        }

        #expect(captured.values.count == 2)
    }

    @Test
    func `a canonical self loop fails before repeating its request or rows`() async throws {
        let captured = CapturedRequests()
        let client = makeClient(transport: CycleTransport(kind: .selfLoop, captured: captured))
        var snapshots: [[Thing]] = []

        await #expect(throws: TestErrors.Failure.http(0)) {
            for try await snapshot in client.streamAllPages(Unidentified.self, path: "/things/") {
                snapshots.append(snapshot)
            }
        }

        #expect(captured.values.count == 1)
        #expect(snapshots == [[Thing(id: 1)]])
    }

    @Test
    func `a two-page cycle fails before repeating its request or rows`() async throws {
        let captured = CapturedRequests()
        let client = makeClient(transport: CycleTransport(kind: .twoPages, captured: captured))
        var snapshots: [[Thing]] = []

        await #expect(throws: TestErrors.Failure.http(0)) {
            for try await snapshot in client.streamAllPages(Unidentified.self, path: "/things/") {
                snapshots.append(snapshot)
            }
        }

        #expect(captured.values.count == 2)
        #expect(snapshots == [[Thing(id: 1)], [Thing(id: 1), Thing(id: 2)]])
    }

    @Test
    func `a non-2xx status surfaces as a mapped HTTP error`() async throws {
        struct FailingTransport: RESTTransport {
            func data(for _: RESTRequest) async throws -> (Data, Int) {
                (Data("nope".utf8), 404)
            }
        }
        await #expect(throws: TestErrors.Failure.http(404)) {
            _ = try await makeClient(transport: FailingTransport())
                .fetch(Thing.self, path: "/things/1")
        }
    }

    @Test(arguments: [(204, ""), (200, #"{"status":"ok"}"#)])
    func `no-content execution accepts empty and JSON success bodies`(status: Int, body: String) async throws {
        let client = makeClient(transport: FixedResponseTransport(data: Data(body.utf8), status: status))
        let request = client.authorizedGET(try #require(URL(string: "https://example.test/mutation")))

        try await client.performNoContent(request: request)
    }

    @Test
    func `no-content execution retains mapped HTTP failures`() async throws {
        let client = makeClient(transport: FixedResponseTransport(data: Data("conflict".utf8), status: 409))
        let request = client.authorizedGET(try #require(URL(string: "https://example.test/mutation")))

        await #expect(throws: TestErrors.Failure.http(409)) {
            try await client.performNoContent(request: request)
        }
    }
}

@Suite("Rate-limit retry policy")
struct RateLimitRetryTests {
    @Test
    func `nonpositive attempts issue no request`() async throws {
        let transport = CountingStatusTransport(status: 200)
        let client = makeClient(transport: transport)
        let request = client.authorizedGET(try #require(URL(string: "https://example.test/things/1")))

        await #expect(throws: TestErrors.Failure.decode) {
            _ = try await client.performWithRetry(Thing.self, request: request, maxAttempts: 0)
        }
        #expect(transport.requestCount == 0)
    }

    @Test
    func `non-idempotent requests are never retried`() async throws {
        let transport = CountingStatusTransport(status: 500)
        let client = makeClient(transport: transport)
        let request = RESTRequest(
            url: try #require(URL(string: "https://example.test/mutation")),
            method: "POST"
        )

        await #expect(throws: TestErrors.Failure.http(500)) {
            _ = try await client.performWithRetry(Thing.self, request: request, maxAttempts: 3)
        }
        #expect(transport.requestCount == 1)
    }

    @Test
    func `retry backoff remains finite for extreme attempt counts`() {
        #expect(PaginatedRESTClient.retryBackoffDelay(retryNumber: .max) == 60)
    }

    @Test
    func `retry-after parses delta seconds and HTTP dates`() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 1994
        components.month = 11
        components.day = 6
        components.hour = 8
        components.minute = 49
        components.second = 7
        let now = try #require(components.date)

        #expect(PaginatedRESTClient.retryAfterDelay(" 120 ", relativeTo: now) == 120)
        #expect(PaginatedRESTClient.retryAfterDelay(
            "Sun, 06 Nov 1994 08:49:37 GMT", relativeTo: now
        ) == 30)
        #expect(PaginatedRESTClient.retryAfterDelay(
            "Sunday, 06-Nov-94 08:49:37 GMT", relativeTo: now
        ) == 30)
        #expect(PaginatedRESTClient.retryAfterDelay(
            "Sun Nov  6 08:49:37 1994", relativeTo: now
        ) == 30)
        #expect(PaginatedRESTClient.retryAfterDelay("not a date", relativeTo: now) == nil)
        #expect(PaginatedRESTClient.retryAfterDelay("-1", relativeTo: now) == nil)
        #expect(PaginatedRESTClient.retryAfterDelay(String(repeating: "9", count: 400), relativeTo: now) == nil)
    }

    @Test
    func `fallback delay is exponential jittered and capped`() {
        #expect(PaginatedRESTClient.rateLimitFallbackDelay(retryNumber: 1, jitter: 0) == 1)
        #expect(PaginatedRESTClient.rateLimitFallbackDelay(retryNumber: 1, jitter: 1) == 1.25)
        #expect(PaginatedRESTClient.rateLimitFallbackDelay(retryNumber: 2, jitter: 0.5) == 2.25)
        #expect(PaginatedRESTClient.rateLimitFallbackDelay(retryNumber: 20, jitter: 1) == 60)
    }

    @Test
    func `a delta Retry-After header controls the retry delay`() async throws {
        let clock = TestClock()
        let sleeper = ControlledSleeper()
        let transport = RetryOnceTransport(retryAfter: "7")
        let client = makeClient(
            transport: transport,
            retryRuntime: RetryRuntime(
                now: { clock.now },
                sleep: { try await sleeper.sleep(for: $0) },
                jitter: { 0 }
            )
        )
        let request = client.authorizedGET(try #require(URL(string: "https://example.test/things/1")))
        let task = Task { try await client.performWithRetry(Thing.self, request: request) }

        while sleeper.requestedDelays.isEmpty { await Task.yield() }
        #expect(sleeper.requestedDelays == [7])
        #expect(transport.requestCount == 1)
        clock.advance(by: 7)
        sleeper.resumeAll()

        #expect(try await task.value == Thing(id: 1))
        #expect(transport.requestCount == 2)
    }

    @Test
    func `an invalid Retry-After header selects the jittered fallback`() async throws {
        let clock = TestClock()
        let sleeper = ControlledSleeper()
        let transport = RetryOnceTransport(retryAfter: "later")
        let client = makeClient(
            transport: transport,
            retryRuntime: RetryRuntime(
                now: { clock.now },
                sleep: { try await sleeper.sleep(for: $0) },
                jitter: { 0.5 }
            )
        )
        let request = client.authorizedGET(try #require(URL(string: "https://example.test/things/1")))
        let task = Task { try await client.performWithRetry(Thing.self, request: request) }

        while sleeper.requestedDelays.isEmpty { await Task.yield() }
        #expect(sleeper.requestedDelays == [1.125])
        clock.advance(by: 1.125)
        sleeper.resumeAll()

        #expect(try await task.value == Thing(id: 1))
        #expect(transport.requestCount == 2)
    }

    @Test
    func `an extreme Retry-After value is capped`() async throws {
        let clock = TestClock()
        let sleeper = ControlledSleeper()
        let transport = RetryOnceTransport(retryAfter: "999999999")
        let client = makeClient(
            transport: transport,
            retryRuntime: RetryRuntime(
                now: { clock.now },
                sleep: { try await sleeper.sleep(for: $0) },
                jitter: { 0 }
            )
        )
        let request = client.authorizedGET(try #require(URL(string: "https://example.test/things/1")))
        let task = Task { try await client.performWithRetry(Thing.self, request: request) }

        while sleeper.requestedDelays.isEmpty { await Task.yield() }
        #expect(sleeper.requestedDelays == [60])
        clock.advance(by: 60)
        sleeper.resumeAll()

        #expect(try await task.value == Thing(id: 1))
    }

    @Test
    func `a terminal rate limit does not delay a later request`() async throws {
        let clock = TestClock()
        let sleeper = ControlledSleeper()
        let transport = TerminalRateLimitTransport()
        let client = makeClient(
            transport: transport,
            retryRuntime: RetryRuntime(
                now: { clock.now },
                sleep: { try await sleeper.sleep(for: $0) },
                jitter: { 0 }
            )
        )
        let limited = client.authorizedGET(try #require(URL(string: "https://example.test/limited")))
        await #expect(throws: TestErrors.Failure.http(429)) {
            _ = try await client.performWithRetry(Thing.self, request: limited, maxAttempts: 1)
        }

        let next = client.authorizedGET(try #require(URL(string: "https://example.test/next")))
        let task = Task { try await client.performWithRetry(Thing.self, request: next, maxAttempts: 1) }
        while transport.requestCount(path: "/next") == 0, sleeper.requestedDelays.isEmpty {
            await Task.yield()
        }
        #expect(sleeper.requestedDelays.isEmpty)
        if !sleeper.requestedDelays.isEmpty {
            clock.advance(by: 60)
            sleeper.resumeAll()
        }
        #expect(try await task.value == Thing(id: 1))
    }

    @Test
    func `cancellation interrupts a Retry-After wait without another request`() async throws {
        let transport = RetryOnceTransport(retryAfter: "3600")
        let client = makeClient(transport: transport)
        let request = client.authorizedGET(try #require(URL(string: "https://example.test/things/1")))
        let task = Task { try await client.performWithRetry(Thing.self, request: request) }

        while transport.requestCount == 0 { await Task.yield() }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.requestCount == 1)
    }

    @Test
    func `concurrent pagination retries share one cooldown deadline`() async throws {
        let clock = TestClock()
        let sleeper = ControlledSleeper()
        let transport = ConcurrentRateLimitTransport()
        let client = makeClient(
            transport: transport,
            retryRuntime: RetryRuntime(
                now: { clock.now },
                sleep: { try await sleeper.sleep(for: $0) },
                jitter: { 0 }
            )
        )
        let task = Task { try await client.fetchAllPages(ThingsPage.self, path: "/things/") }

        while sleeper.requestedDelays.count < 2 { await Task.yield() }
        #expect(sleeper.requestedDelays == [10, 10])
        #expect(transport.requestCount(for: 2) == 1)
        #expect(transport.requestCount(for: 3) == 1)

        clock.advance(by: 10)
        sleeper.resumeAll()
        #expect(try await task.value == things(1 ... 6))
        #expect(transport.requestCount(for: 2) == 2)
        #expect(transport.requestCount(for: 3) == 2)
    }
}

private func things(_ ids: ClosedRange<Int>) -> [Thing] {
    ids.map(Thing.init(id:))
}

@Suite("Page-count estimation")
struct PageCountTests {
    @Test
    func `a missing identity on page two aborts before emitting that page`() async throws {
        let log = RequestLog()
        let transport = ScriptedTransport(
            pages: [Array(1 ... 10), Array(11 ... 20)],
            total: 20,
            outOfRange: .notFound,
            log: log
        )
        let client = makeClient(transport: transport)
        var snapshots: [[Thing]] = []

        await #expect(throws: TestErrors.Failure.decode) {
            for try await snapshot in client.streamAllPages(PartialIdentityPage.self, path: "/things/") {
                snapshots.append(snapshot)
            }
        }

        #expect(log.requestedPages.sorted() == [1, 2])
        #expect(snapshots == [things(1 ... 10)])
    }

    /// The page count must come from the page size the client asked for, not from the
    /// first response's item count. A first page shortened by server-side filtering makes
    /// the inferred divisor too small, over-estimating the page count and sending the
    /// client after pages that do not exist - and a single 404 there fails the task group,
    /// discarding every record already fetched.
    @Test
    func `a short first page does not over-estimate the page count`() async throws {
        let log = RequestLog()
        let transport = ScriptedTransport(
            pages: [Array(1 ... 6), Array(7 ... 16), Array(17 ... 25)],
            total: 25,
            outOfRange: .notFound,
            log: log
        )
        let items = try await makeClient(transport: transport).fetchAllPages(TenPerPage.self, path: "/things/")
        #expect(items == things(1 ... 25))
        #expect(log.requestedPages.sorted() == [1, 2, 3])
    }

    /// The tail `next_page` must not be taken from a page that turned out to be out of
    /// range. A server that clamps such a page to page 1 hands back a `next_page` pointing
    /// at page 2, which re-walks the entire list.
    @Test
    func `a clamped final page does not trigger a full re-walk`() async throws {
        let log = RequestLog()
        let transport = ScriptedTransport(
            pages: [Array(1 ... 10), Array(11 ... 18)],
            total: 25,
            outOfRange: .clampToFirstPage,
            log: log
        )
        let items = try await makeClient(transport: transport).fetchAllPages(TenPerPage.self, path: "/things/")
        #expect(items == things(1 ... 18))
        #expect(log.requestedPages.sorted() == [1, 2, 3])
    }

    @Test
    func `a duplicate-only estimated tail still follows a forward next page`() async throws {
        let log = RequestLog()
        let transport = ScriptedTransport(
            pages: [Array(1 ... 10), Array(11 ... 20), Array(11 ... 20), Array(21 ... 25)],
            total: 30,
            outOfRange: .notFound,
            log: log
        )

        let items = try await makeClient(transport: transport)
            .fetchAllPages(TenPerPage.self, path: "/things/")

        #expect(items == things(1 ... 25))
        #expect(log.requestedPages.sorted() == [1, 2, 3, 4])
    }

    /// `pageCount` derives from a server-supplied `total`, so it needs the same valve the
    /// sequential walk has - otherwise one bogus `total` amplifies into thousands of
    /// requests for a handful of records.
    @Test
    func `an implausible total is capped rather than amplified into thousands of requests`() async throws {
        let log = RequestLog()
        let transport = ScriptedTransport(pages: [Array(1 ... 10)], total: 50000, outOfRange: .notFound, log: log)
        await #expect(throws: TestErrors.Failure.http(0)) {
            _ = try await makeClient(transport: transport).fetchAllPages(TenPerPage.self, path: "/things/")
        }
        #expect(log.requestedPages == [1])
    }

    /// `total` is decoded straight from JSON, so `total + pageSize - 1` on `Int.max` used
    /// to trap the process. It must surface as an error instead.
    @Test
    func `a total large enough to overflow the page arithmetic surfaces as an error`() async throws {
        let json = #"{"things":[{"id":1},{"id":2}],"next_page":null,"total":9223372036854775807}"#
        await #expect(throws: TestErrors.Failure.decode) {
            _ = try await makeClient(transport: FixedFirstPageTransport(json: json))
                .fetchAllPages(TenPerPage.self, path: "/things/")
        }
    }

    @Test
    func `a negative total surfaces as an error`() async throws {
        let json = #"{"things":[{"id":1},{"id":2}],"next_page":null,"total":-1}"#
        await #expect(throws: TestErrors.Failure.decode) {
            _ = try await makeClient(transport: FixedFirstPageTransport(json: json))
                .fetchAllPages(TenPerPage.self, path: "/things/")
        }
    }

    @Test
    func `an enormous page size cannot overflow page count arithmetic`() async throws {
        let json = #"{"things":[{"id":1}],"next_page":null,"total":2}"#

        let items = try await makeClient(transport: FixedFirstPageTransport(json: json))
            .fetchAllPages(HugePageSize.self, path: "/things/")

        #expect(items == [Thing(id: 1)])
    }
}

@Suite("Path selection and isolation")
struct PathSelectionTests {
    /// `identity(of:)` documents that items with no stable id take the sequential path.
    /// The parallel path requests pages speculatively, so entering it with de-duplication
    /// disabled lets a clamped out-of-range page duplicate rows.
    @Test
    func `a nil identity takes the sequential path rather than duplicating rows`() async throws {
        let log = RequestLog()
        let transport = ScriptedTransport(
            pages: [Array(1 ... 10), Array(11 ... 18)],
            total: 25,
            outOfRange: .clampToFirstPage,
            log: log
        )
        let items = try await makeClient(transport: transport).fetchAllPages(Unidentified.self, path: "/things/")
        #expect(items == things(1 ... 18))
        // The sequential walk follows `next_page` and never requests a page by number.
        #expect(log.requestedPages == [1, 2])
    }

    /// `streamAllPages` is `nonisolated`, so the pipeline it starts - and the transport
    /// calls it makes - run off the main actor even when the caller is on it.
    @Test @MainActor
    func `the pagination pipeline runs off the main actor`() async throws {
        let log = RequestLog()
        let transport = ScriptedTransport(
            pages: [Array(1 ... 10), Array(11 ... 20), Array(21 ... 25)],
            total: 25,
            outOfRange: .notFound,
            log: log
        )
        let items = try await makeClient(transport: transport).fetchAllPages(TenPerPage.self, path: "/things/")
        #expect(items == things(1 ... 25))
        #expect(log.requestedPages.count == 3)
        #expect(log.mainThreadRequestCount == 0)
    }
}
