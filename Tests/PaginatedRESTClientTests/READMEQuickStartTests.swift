import Foundation
import PaginatedRESTClient
import Testing

// Mirrors the README quick start so that example stays compiling (issue #112).
// Uses `nonisolated` where the test target's MainActor default isolation requires it.

private nonisolated struct Item: Decodable, Sendable {
    let id: Int
}

private nonisolated struct ItemsPage: PagedResponse {
    let items: [Item]
    let nextPage: String?
    let total: Int?

    var pageItems: [Item] { items }

    nonisolated static func identity(of item: Item) -> AnyHashable? { item.id }

    enum CodingKeys: String, CodingKey {
        case items
        case nextPage = "next_page"
        case total
    }
}

private enum APIError: Error {
    case missingKey, http(Int), decode(String), offline
}

private struct APIErrors: RESTTransportErrorMapping {
    nonisolated func missingAPIKey() -> Error { APIError.missingKey }
    nonisolated func http(status: Int, body _: String) -> Error { APIError.http(status) }
    nonisolated func decode(_ detail: String) -> Error { APIError.decode(detail) }
    nonisolated func network(_: URLError) -> Error { APIError.offline }
    nonisolated func isTransient(_ error: Error) -> Bool {
        if case let APIError.http(code) = error {
            return code == 429 || (500 ... 599).contains(code)
        }
        if case APIError.offline = error { return true }
        return false
    }
}

private nonisolated struct READMEQuickStartTransport: LegacyRESTTransport {
    func data(for _: RESTRequest) async throws -> (Data, Int) {
        let json = #"{"items":[{"id":1}],"next_page":null,"total":1}"#
        return (Data(json.utf8), 200)
    }
}

@Suite("README quick start")
struct READMEQuickStartTests {
    @Test
    func `the README quick start constructs and fetches`() async throws {
        let token = "readme-token"
        let client = try PaginatedRESTClient(
            apiKey: token,
            baseURL: URL(string: "https://api.example.com")!,
            transport: READMEQuickStartTransport(),
            decoderFactory: { JSONDecoder() },
            encoderFactory: { JSONEncoder() },
            errors: APIErrors()
        )

        let items = try await client.fetchAllPages(ItemsPage.self, path: "/items/")
        #expect(items.map(\.id) == [1])
    }
}
