//
//  URLSessionTransport.swift
//  PaginatedRESTClient
//
//  The batteries-included default transport, layered over `URLSession`. This is the
//  behaviour the paginator shipped before the transport became pluggable: a plain
//  `URLSession.data(for:)` round-trip. It is Foundation-only, so the core has no
//  third-party dependency and stays Linux-clean.
//

import Foundation
// On Linux, URLSession lives in FoundationNetworking rather than Foundation.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `RESTTransport` backed by `URLSession`. Constructed with `URLSession.shared` by
/// default; pass a configured session (custom timeouts, an ephemeral configuration, a
/// stub `URLProtocol`) when you need one.
public struct URLSessionTransport: RESTTransport {
    nonisolated let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public nonisolated func data(for request: RESTRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: Self.urlRequest(from: request))
        guard let http = response as? HTTPURLResponse else {
            // A non-HTTP response is a transport-level anomaly; surface it as a URLError
            // so the paginator routes it through the error mapping's `network(_:)` case.
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }

    /// Translates the backend-neutral `RESTRequest` into a `URLRequest`.
    private nonisolated static func urlRequest(from request: RESTRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }
}
