import Foundation
import PaginatedRESTClient
import Testing

@Test
func `RESTItemIdentity is Hashable and Sendable`() {
    let first = RESTItemIdentity(7)
    let same = RESTItemIdentity(7)
    let other = RESTItemIdentity(8)
    #expect(first == same)
    #expect(first != other)
    var identities: Set<RESTItemIdentity> = []
    #expect(identities.insert(first).inserted)
    #expect(!identities.insert(same).inserted)
    #expect(identities.insert(other).inserted)
}

@Test
func `pagination HTTP attempt budget defaults to pages times retries`() throws {
    let client = try PaginatedRESTClient(
        apiKey: "key",
        baseURL: URL(string: "https://example.test")!,
        decoderFactory: { JSONDecoder() },
        encoderFactory: { JSONEncoder() },
        errors: BudgetErrors(),
        maxSequentialPages: 10,
        maxAttempts: 3
    )
    #expect(client.maxPaginationHTTPAttempts == 30)
}

private struct BudgetErrors: RESTTransportErrorMapping {
    nonisolated func missingAPIKey() -> Error { URLError(.userAuthenticationRequired) }
    nonisolated func http(status: Int, body _: String) -> Error { URLError(.badServerResponse) }
    nonisolated func decode(_: String) -> Error { URLError(.cannotDecodeContentData) }
    nonisolated func network(_ error: URLError) -> Error { error }
    nonisolated func invalidRequest(_: String) -> Error { URLError(.badURL) }
    nonisolated func isTransient(_: Error) -> Bool { false }
}
