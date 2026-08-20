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
private nonisolated func makePaginatedRESTClientFromNonisolatedContext() throws -> PaginatedRESTClient {
    try PaginatedRESTClient(
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

private nonisolated struct IsolationProbeValues {
    let request: RESTRequest
    let response: RESTResponse
    let overflow: RESTResponseTooLargeError
}

private nonisolated func makeRESTValuesFromNonisolatedContext() -> IsolationProbeValues {
    let request = RESTRequest(
        url: URL(string: "https://example.test/item")!,
        method: "GET"
    )
    let response = RESTResponse(data: Data(), statusCode: 200)
    let overflow = RESTResponseTooLargeError(statusCode: 200, limit: 8, phase: .body)
    return IsolationProbeValues(request: request, response: response, overflow: overflow)
}

@Suite("Initializer isolation")
struct InitializerIsolationTests {
    @Test
    func `paginatedRESTClient can be constructed from a nonisolated context`() throws {
        _ = try makePaginatedRESTClientFromNonisolatedContext()
    }

    @Test
    func `urlSessionTransport can be constructed from a nonisolated context`() {
        _ = makeURLSessionTransportFromNonisolatedContext()
    }

    @Test
    func `rest request response and overflow errors construct from a nonisolated context`() {
        let values = makeRESTValuesFromNonisolatedContext()
        #expect(values.request.method == "GET")
        #expect(values.response.statusCode == 200)
        #expect(values.overflow.limit == 8)
    }
}
