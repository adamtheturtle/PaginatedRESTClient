import Foundation
import PaginatedRESTClient
import Testing

/// Minimal error mapping used only to prove initializers are callable off MainActor.
private struct IsolationProbeErrors: RESTTransportErrorMapping {
    enum Failure: Error {
        case unused
    }

    nonisolated func missingAPIKey() -> any Error { Failure.unused }
    nonisolated func http(status _: Int, body _: String) -> any Error { Failure.unused }
    nonisolated func decode(_: String) -> any Error { Failure.unused }
    nonisolated func network(_: URLError) -> any Error { Failure.unused }
    nonisolated func isTransient(_: any Error) -> Bool { false }
}

/// Downstream-style compile probe: constructing from a nonisolated function must compile
/// under the module's default MainActor isolation (issues #64 and #65).
private nonisolated func makePaginatedRESTClientFromNonisolatedContext() -> PaginatedRESTClient {
    PaginatedRESTClient(
        apiKey: "key",
        baseURL: URL(string: "https://example.test")!,
        decoderFactory: { JSONDecoder() },
        encoderFactory: { JSONEncoder() },
        errors: IsolationProbeErrors()
    )
}

private nonisolated func makeURLSessionTransportFromNonisolatedContext() -> URLSessionTransport {
    URLSessionTransport()
}

private nonisolated func makeRESTValuesFromNonisolatedContext() -> (RESTRequest, RESTResponse, RESTResponseTooLargeError) {
    let request = RESTRequest(
        url: URL(string: "https://example.test/item")!,
        method: "GET"
    )
    let response = RESTResponse(data: Data(), statusCode: 200)
    let overflow = RESTResponseTooLargeError(statusCode: 200, limit: 8, phase: .body)
    return (request, response, overflow)
}

@Suite("Initializer isolation")
struct InitializerIsolationTests {
    @Test
    func `PaginatedRESTClient can be constructed from a nonisolated context`() {
        _ = makePaginatedRESTClientFromNonisolatedContext()
    }

    @Test
    func `URLSessionTransport can be constructed from a nonisolated context`() {
        _ = makeURLSessionTransportFromNonisolatedContext()
    }

    @Test
    func `REST request response and overflow errors construct from a nonisolated context`() {
        let (request, response, overflow) = makeRESTValuesFromNonisolatedContext()
        #expect(request.method == "GET")
        #expect(response.statusCode == 200)
        #expect(overflow.limit == 8)
    }
}
