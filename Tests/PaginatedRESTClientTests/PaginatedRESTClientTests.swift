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

private func makeClient(transport: any RESTTransport = StubTransport()) -> PaginatedRESTClient {
    PaginatedRESTClient(
        apiKey: "test-key",
        baseURL: URL(string: "https://example.test")!,
        transport: transport,
        decoderFactory: { JSONDecoder() },
        encoderFactory: { JSONEncoder() },
        errors: TestErrors()
    )
}

// MARK: - Tests

@Suite("PaginatedRESTClient")
struct PaginatedRESTClientTests {
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
}

private func things(_ ids: ClosedRange<Int>) -> [Thing] {
    ids.map(Thing.init(id:))
}

@Suite("Page-count estimation")
struct PageCountTests {
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
