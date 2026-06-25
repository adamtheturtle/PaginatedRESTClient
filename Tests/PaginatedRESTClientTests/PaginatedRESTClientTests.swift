import Foundation
@testable import PaginatedRESTClient
import Testing

// MARK: - Test doubles

/// A minimal error mapping: the transport names no domain error, so the tests supply a
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

    nonisolated static func identity(of item: Thing) -> AnyHashable? {
        item.id
    }

    enum CodingKeys: String, CodingKey { case things; case nextPage = "next_page"; case total }
}

/// Serves a fixed two-page fixture keyed off the `page` query item, so pagination can be
/// exercised with no real networking. `nonisolated` because the URL loading system calls
/// `startLoading()` off the main actor (matching the module's MainActor default isolation).
private final nonisolated class StubURLProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value
        let json = switch page {
        case nil, "1":
            #"{"things":[{"id":1},{"id":2}],"next_page":"https://example.test/things/?page=2","total":3}"#
        case "2":
            #"{"things":[{"id":3}],"next_page":null,"total":3}"#
        default:
            #"{"things":[],"next_page":null,"total":3}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeClient() -> PaginatedRESTClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return PaginatedRESTClient(
        apiKey: "test-key",
        baseURL: URL(string: "https://example.test")!,
        session: URLSession(configuration: config),
        decoderFactory: { JSONDecoder() },
        encoderFactory: { JSONEncoder() },
        errors: TestErrors(),
        logger: .init(subsystem: "PaginatedRESTClientTests", category: "test")
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
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = try PaginatedRESTClient(
            apiKey: "",
            baseURL: #require(URL(string: "https://example.test")),
            session: URLSession(configuration: config),
            decoderFactory: { JSONDecoder() },
            encoderFactory: { JSONEncoder() },
            errors: TestErrors(),
            logger: .init(subsystem: "PaginatedRESTClientTests", category: "test")
        )
        await #expect(throws: TestErrors.Failure.missingAPIKey) {
            _ = try await client.fetch(Thing.self, path: "/things/1")
        }
    }
}
