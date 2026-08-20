@testable import PaginatedRESTClient
import Foundation
import Synchronization
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Authenticated redirect policy")
struct RedirectPolicyTests {
    @Test
    func `authenticated redirects are allowed only within their original origin`() async throws {
        let origin = URL(string: "https://api.example.test/v1/resources")!
        let delegate = SameOriginRedirectDelegate(requestURL: origin, forwardingDelegate: nil)
        let task = URLSession.shared.dataTask(with: origin)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(
            url: origin,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        var redirectedRequest = URLRequest(url: URL(string: "https://attacker.example/resources")!)
        redirectedRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let sameOriginRequest = URLRequest(url: URL(string: "https://api.example.test/v2/resources")!)

        let rejected = await redirectDecision(
            from: delegate,
            task: task,
            response: response,
            request: redirectedRequest
        )
        let accepted = await redirectDecision(
            from: delegate,
            task: task,
            response: response,
            request: sameOriginRequest
        )

        #expect(rejected == nil)
        #expect(accepted?.url == sameOriginRequest.url)
    }

    @Test
    func `unauthenticated requests may follow safe cross-origin redirects`() async throws {
        let origin = URL(string: "https://api.example.test/public")!
        let delegate = SameOriginRedirectDelegate(
            requestURL: origin,
            requiresSameOrigin: false,
            forwardingDelegate: nil
        )
        let task = URLSession.shared.dataTask(with: origin)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(
            url: origin,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let publicRequest = URLRequest(url: URL(string: "https://cdn.example.test/object")!)
        var credentialedRequest = publicRequest
        credentialedRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let accepted = await redirectDecision(
            from: delegate,
            task: task,
            response: response,
            request: publicRequest
        )
        let rejected = await redirectDecision(
            from: delegate,
            task: task,
            response: response,
            request: credentialedRequest
        )

        #expect(accepted?.url == publicRequest.url)
        #expect(rejected == nil)
    }

    @Test
    func `cross-origin delayed request substitutions are cancelled`() async {
        let origin = URL(string: "https://api.example.test/v1/resources")!
        let replacement = URLRequest(url: URL(string: "https://attacker.example/resources")!)
        let delegate = SameOriginRedirectDelegate(
            requestURL: origin,
            forwardingDelegate: DelayedRequestSubstitutionDelegate(replacement: replacement)
        )
        let task = URLSession.shared.dataTask(with: origin)
        defer { task.cancel() }

        let decision = await withCheckedContinuation { continuation in
            delegate.urlSession(
                URLSession.shared,
                task: task,
                willBeginDelayedRequest: URLRequest(url: origin),
                completionHandler: { continuation.resume(returning: ($0, $1)) }
            )
        }

        #expect(decision.0 == .cancel)
        #expect(decision.1 == nil)
    }

    @Test
    func `only scheme host and effective port define the authenticated origin`() {
        let origin = URL(string: "https://api.example.test/v1/resources")!

        #expect(SameOriginRedirectDelegate.hasSameOrigin(
            origin,
            URL(string: "https://API.EXAMPLE.TEST:443/v2/resources")!
        ))
        #expect(!SameOriginRedirectDelegate.hasSameOrigin(origin, URL(string: "https://other.example/test")!))
        #expect(!SameOriginRedirectDelegate.hasSameOrigin(origin, URL(string: "http://api.example.test/test")!))
        #expect(!SameOriginRedirectDelegate.hasSameOrigin(origin, URL(string: "https://api.example.test:444/test")!))
    }

    @Test
    func `equivalent IPv6 literals define the same authenticated origin`() {
        #expect(SameOriginRedirectDelegate.hasSameOrigin(
            URL(string: "https://[::1]/resources")!,
            URL(string: "https://[0:0:0:0:0:0:0:1]:443/other")!
        ))
        #expect(!SameOriginRedirectDelegate.hasSameOrigin(
            URL(string: "https://[::1]/resources")!,
            URL(string: "https://[::2]/resources")!
        ))
    }

    @Test
    func `file-backed bodies can provide a fresh stream`() throws {
        let expected = Data("stream me again".utf8)
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appending(path: "PaginatedRESTClient-\(UUID().uuidString).body")
        try expected.write(to: bodyFileURL)
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }
        let origin = URL(string: "https://api.example.test/upload")!
        let delegate = SameOriginRedirectDelegate(
            requestURL: origin,
            bodyFileURL: bodyFileURL,
            forwardingDelegate: nil
        )
        let task = URLSession.shared.dataTask(with: origin)
        defer { task.cancel() }

        let received = Mutex<Data?>(nil)
        delegate.urlSession(
            URLSession.shared,
            task: task,
            needNewBodyStream: { stream in
                received.withLock { $0 = readBodyStream(stream) }
            }
        )

        #expect(received.withLock { $0 } == expected)
    }

    #if os(Linux)
    @Test
    func `the Linux bounded loader replays a file-backed body`() throws {
        let expected = Data("Linux replay".utf8)
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appending(path: "PaginatedRESTClient-\(UUID().uuidString).body")
        try expected.write(to: bodyFileURL)
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }
        let origin = URL(string: "https://api.example.test/upload")!
        let loader = BoundedURLSessionLoader(
            successResponseLimit: 1024,
            errorResponseLimit: 1024,
            requestURL: origin,
            bodyFileURL: bodyFileURL,
            forwardingDelegate: nil
        )
        let task = URLSession.shared.dataTask(with: origin)
        defer { task.cancel() }
        let received = Mutex<Data?>(nil)

        loader.urlSession(
            URLSession.shared,
            task: task,
            needNewBodyStream: { stream in
                received.withLock { $0 = readBodyStream(stream) }
            }
        )

        #expect(received.withLock { $0 } == expected)
    }
    #endif

    @Test(arguments: [
        "https://user@api.example.test/v2/resources",
        "https://user:password@api.example.test/v2/resources"
    ])
    func `same-origin redirects with userinfo are rejected`(destination: String) async throws {
        let origin = URL(string: "https://api.example.test/v1/resources")!
        let delegate = SameOriginRedirectDelegate(requestURL: origin, forwardingDelegate: nil)
        let task = URLSession.shared.dataTask(with: origin)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(
            url: origin,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let rejected = await redirectDecision(
            from: delegate,
            task: task,
            response: response,
            request: URLRequest(url: URL(string: destination)!)
        )
        #expect(rejected == nil)
    }

    private func redirectDecision(
        from delegate: SameOriginRedirectDelegate,
        task: URLSessionTask,
        response: HTTPURLResponse,
        request: URLRequest
    ) async -> URLRequest? {
        await withCheckedContinuation { continuation in
            delegate.urlSession(
                URLSession.shared,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
    }

}

private nonisolated final class DelayedRequestSubstitutionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    let replacement: URLRequest

    init(replacement: URLRequest) {
        self.replacement = replacement
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willBeginDelayedRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    ) {
        completionHandler(.useNewRequest, replacement)
    }
}

private nonisolated func readBodyStream(_ stream: InputStream?) -> Data {
    guard let stream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { return result }
        result.append(contentsOf: buffer.prefix(count))
    }
}
