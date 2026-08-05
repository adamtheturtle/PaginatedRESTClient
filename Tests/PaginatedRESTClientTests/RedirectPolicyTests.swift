@testable import PaginatedRESTClient
import Foundation
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
