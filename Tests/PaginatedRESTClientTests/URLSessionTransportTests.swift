@testable import PaginatedRESTClient
import Foundation
import Synchronization
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("URLSession transport response limits")
struct URLSessionTransportTests {
    @Test
    func `default transport uses an isolated ephemeral session`() {
        let transport = URLSessionTransport()
        #expect(transport.session.configuration.urlCache !== URLSession.shared.configuration.urlCache)
        #expect(
            transport.session.configuration.httpCookieStorage
                !== URLSession.shared.configuration.httpCookieStorage
        )
    }

    @Test
    func `a file-backed request body is delivered through a stream`() async throws {
        let body = Data(repeating: 0xA5, count: 2 * 1024 * 1024)
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appending(path: "PaginatedRESTClient-\(UUID().uuidString).body")
        try body.write(to: bodyFileURL)
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        FileBodyURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileBodyURLProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))
        let request = RESTRequest(
            url: URL(string: "https://example.test/upload")!,
            method: "POST",
            headers: ["Content-Length": String(body.count)],
            bodyFileURL: bodyFileURL
        )

        let response = try await transport.response(for: request)

        #expect(response.statusCode == 200)
        #expect(request.body == nil)
        #expect(FileBodyURLProtocol.receivedThroughStream())
        #expect(FileBodyURLProtocol.receivedBody() == body)
    }

    @Test
    func `multiple request body sources are rejected before transport`() async {
        let request = RESTRequest(
            url: URL(string: "https://example.test/upload")!,
            method: "POST",
            body: Data([1]),
            bodyFileURL: FileManager.default.temporaryDirectory.appending(path: "body")
        )

        await #expect(throws: RESTRequestBodyError.multipleSources) {
            _ = try await URLSessionTransport().response(for: request)
        }
    }

    @Test(arguments: [
        URL(string: "file:///tmp/body")!,
        URL(string: "ftp://example.test/file")!,
        URL(string: "https://user@example.test/path")!
    ])
    func `non-HTTP request URLs are rejected before transport`(url: URL) async {
        let request = RESTRequest(url: url, method: "GET")

        await #expect(throws: RESTRequestError.unsupportedURL(url)) {
            _ = try await URLSessionTransport().response(for: request)
        }
    }

    @Test(arguments: ["", "GET ", "GET\r\nX-Evil: true", "PÖST"])
    func `invalid HTTP method tokens are rejected before transport`(method: String) async {
        let request = RESTRequest(url: URL(string: "https://example.test/")!, method: method)

        await #expect(throws: RESTRequestError.invalidHTTPMethod(method)) {
            _ = try await URLSessionTransport().response(for: request)
        }
    }

    @Test
    func `duplicate case-variant request headers are rejected before transport`() async {
        let request = RESTRequest(
            url: URL(string: "https://example.test/")!,
            method: "GET",
            headers: ["Authorization": "Bearer a", "authorization": "Bearer b"]
        )

        do {
            _ = try await URLSessionTransport().response(for: request)
            Issue.record("Expected duplicate header rejection")
        } catch let error as RESTRequestError {
            guard case .duplicateHeaderField = error else {
                Issue.record("Unexpected RESTRequestError \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test
    func `invalid HTTP header fields are rejected before transport`() async {
        let request = RESTRequest(
            url: URL(string: "https://example.test/")!,
            method: "GET",
            headers: ["Good\r\nInjected": "value"]
        )

        await #expect(throws: RESTRequestError.invalidHeaderField) {
            _ = try await URLSessionTransport().response(for: request)
        }
    }

    @Test
    func `a directory is rejected as a file-backed request body`() async throws {
        let request = RESTRequest(
            url: try #require(URL(string: "https://example.test/upload")),
            method: "POST",
            bodyFileURL: FileManager.default.temporaryDirectory
        )

        await #expect(throws: RESTRequestBodyError.unreadableBodyFile(
            FileManager.default.temporaryDirectory
        )) {
            _ = try await URLSessionTransport().response(for: request)
        }
    }

    @Test
    func `negative response limits clamp to zero without crashing`() {
        let transport = URLSessionTransport(successResponseLimit: -1, errorResponseLimit: -2)
        #expect(transport.successResponseLimit == 0)
        #expect(transport.errorResponseLimit == 0)
    }

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
        #expect(error?.phase == .body)
        // Apple streams byte-by-byte so rejection lands at exactly `limit`; Linux may
        // receive a larger first chunk and reject with zero accepted bytes.
        #expect((error?.observedByteCount ?? -1) <= 8)
    }

    @Test
    func `HEAD ignores representation Content-Length when no bytes arrive`() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeadContentLengthURLProtocol.self]
        let transport = URLSessionTransport(
            session: URLSession(configuration: configuration),
            successResponseLimit: 1
        )
        let request = RESTRequest(url: try #require(URL(string: "https://example.test/head")), method: "HEAD")

        let response = try await transport.response(for: request)
        #expect(response.statusCode == 200)
        #expect(response.data.isEmpty)
    }

    @Test
    func `a mismatched Content-Length for a file body is rejected before upload`() async throws {
        let body = Data(repeating: 0x11, count: 32)
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appending(path: "PaginatedRESTClient-\(UUID().uuidString).body")
        try body.write(to: bodyFileURL)
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        let request = RESTRequest(
            url: URL(string: "https://example.test/upload")!,
            method: "POST",
            headers: ["Content-Length": "999"],
            bodyFileURL: bodyFileURL
        )

        await #expect(throws: RESTRequestBodyError.contentLengthMismatch(expected: 32, declared: "999")) {
            _ = try await URLSessionTransport().response(for: request)
        }
    }

    @Test
    func `RESTResponse header assignment re-canonicalizes names`() {
        var response = RESTResponse(
            data: Data(),
            statusCode: 200,
            headers: ["X-Test": "one", "x-test": "two"]
        )
        #expect(response.headers == ["x-test": "one"])
        response.headers = ["Retry-After": "1", "retry-after": "2"]
        #expect(response.headers == ["retry-after": "1"])
        #expect(response.value(forHTTPHeaderField: "RETRY-AFTER") == "1")
    }

    @Test
    func `the client maps a response overflow through its decode error policy`() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseLimitURLProtocol.self]
        let client = try PaginatedRESTClient(
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

    @Test
    func `the client maps an error-status overflow through its http error policy`() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseLimitURLProtocol.self]
        let client = try PaginatedRESTClient(
            apiKey: "key",
            baseURL: URL(string: "https://example.test")!,
            transport: URLSessionTransport(
                session: URLSession(configuration: configuration),
                errorResponseLimit: 8
            ),
            decoderFactory: { JSONDecoder() },
            encoderFactory: { JSONEncoder() },
            errors: ResponseLimitErrors()
        )

        let error = await #expect(throws: ResponseLimitFailure.self) {
            _ = try await client.fetch(ResponseLimitValue.self, path: "/500")
        }

        guard case let .http(status, body) = error else {
            Issue.record("Expected a mapped HTTP failure")
            return
        }
        #expect(status == 500)
        #expect(body.contains("exceeded the 8-byte limit"))
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

private final nonisolated class FileBodyURLProtocol: URLProtocol {
    private struct State {
        var body = Data()
        var usedStream = false
    }

    private static let state = Mutex(State())

    static func reset() {
        state.withLock {
            $0.body = Data()
            $0.usedStream = false
        }
    }

    static func receivedBody() -> Data {
        state.withLock { $0.body }
    }

    static func receivedThroughStream() -> Bool {
        state.withLock { $0.usedStream }
    }

    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stream = request.httpBodyStream
        let received = Self.read(stream)
        Self.state.withLock {
            $0.body = received
            $0.usedStream = request.httpBody == nil && stream != nil
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

private enum ResponseLimitFailure: Error {
    case decode(String)
    case http(Int, String)
    case unexpected
}

private struct ResponseLimitErrors: RESTTransportErrorMapping {
    nonisolated func missingAPIKey() -> any Error { ResponseLimitFailure.unexpected }
    nonisolated func http(status: Int, body: String) -> any Error { ResponseLimitFailure.http(status, body) }
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

private final nonisolated class HeadContentLengthURLProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "1000000"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
