@testable import PaginatedRESTClient
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("URLSession transport response limits")
struct URLSessionTransportTests {
    @Test(arguments: [(200, 8, 64), (500, 64, 8)])
    func `success and error bodies use separate streaming limits`(
        status: Int,
        successLimit: Int,
        errorLimit: Int
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseLimitURLProtocol.self]
        let transport = URLSessionTransport(
            session: URLSession(configuration: configuration),
            successResponseLimit: successLimit,
            errorResponseLimit: errorLimit
        )
        let request = RESTRequest(url: URL(string: "https://example.test/\(status)")!, method: "GET")

        let error = await #expect(throws: RESTResponseTooLargeError.self) {
            _ = try await transport.response(for: request)
        }

        #expect(error?.statusCode == status)
        #expect(error?.limit == 8)
    }

    @Test
    func `the client maps a response overflow through its decode error policy`() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseLimitURLProtocol.self]
        let client = PaginatedRESTClient(
            apiKey: "key",
            baseURL: URL(string: "https://example.test")!,
            transport: URLSessionTransport(
                session: URLSession(configuration: configuration),
                successResponseLimit: 8
            ),
            decoderFactory: { JSONDecoder() },
            encoderFactory: { JSONEncoder() },
            errors: ResponseLimitErrors()
        )

        let error = await #expect(throws: ResponseLimitFailure.self) {
            _ = try await client.fetch(ResponseLimitValue.self, path: "/200")
        }

        guard case let .decode(detail) = error else {
            Issue.record("Expected a mapped decode failure")
            return
        }
        #expect(detail.contains("HTTP 200 response exceeded the 8-byte limit"))
    }

    #if os(Linux)
    @Test
    func `the Linux bounded loader preserves the supplied session delegate`() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseLimitURLProtocol.self]
        let delegate = CompletionRecordingDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        let transport = URLSessionTransport(session: session)
        let request = RESTRequest(url: URL(string: "https://example.test/200")!, method: "GET")

        _ = try await transport.response(for: request)

        #expect(delegate.didCompleteTask)
    }
    #endif
}

private enum ResponseLimitFailure: Error {
    case decode(String)
    case unexpected
}

private struct ResponseLimitErrors: RESTTransportErrorMapping {
    nonisolated func missingAPIKey() -> any Error { ResponseLimitFailure.unexpected }
    nonisolated func http(status _: Int, body _: String) -> any Error { ResponseLimitFailure.unexpected }
    nonisolated func decode(_ detail: String) -> any Error { ResponseLimitFailure.decode(detail) }
    nonisolated func network(_: URLError) -> any Error { ResponseLimitFailure.unexpected }
    nonisolated func isTransient(_: any Error) -> Bool { false }
}

private nonisolated struct ResponseLimitValue: Decodable, Sendable {}

#if os(Linux)
private final nonisolated class CompletionRecordingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completionRecorded = false

    var didCompleteTask: Bool {
        lock.withLock { completionRecorded }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError _: (any Error)?) {
        lock.withLock { completionRecorded = true }
    }
}
#endif

private final nonisolated class ResponseLimitURLProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let status = Int(url.lastPathComponent),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 97, count: 32))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
